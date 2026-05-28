// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title RiskEngine
 * @notice Computes impermanent loss and decomposes positions into risk layers
 */
contract RiskEngine {
    using PoolIdLibrary for PoolKey;

    // Q96.96 fixed point math
    uint256 constant Q96 = 2 ** 96;

    // ============ Structs ============

    struct RiskProfile {
        uint256 ilExposureBps;      // Current IL exposure in basis points
        uint256 maxLossBps;         // Maximum possible IL for this position
        uint256 deltaSensitivity;   // How sensitive to price moves (gamma-like)
        uint256 timeDecay;          // Time-based risk adjustment
    }

    // ============ State ============

    // poolId => historical volatility (used for risk calibration)
    mapping(PoolId => uint256) public poolVolatility;

    // ============ IL Computation ============

    /**
     * @notice Compute realized impermanent loss between entry and exit
     * @param entryPrice TWAP price at position entry (Q96.96)
     * @param exitPrice TWAP price at position exit (Q96.96)
     * @param entryLiquidity Liquidity amount at entry
     * @param exitLiquidity Liquidity amount at exit (may differ due to partial removal)
     * @return ilBps Realized IL in basis points (0-10000)
     */
    function computeIL(
        uint256 entryPrice,
        uint256 exitPrice,
        uint256 entryLiquidity,
        uint256 exitLiquidity
    ) external pure returns (uint256 ilBps) {
        // IL formula for constant product AMM:
        // IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1
        // Where priceRatio = exitPrice / entryPrice

        if (entryPrice == 0 || exitPrice == 0) return 0;

        // Scale to avoid precision loss
        uint256 priceRatio = (exitPrice * 1e18) / entryPrice;

        // sqrt(priceRatio) using Babylonian method
        uint256 sqrtRatio = _sqrt(priceRatio);

        // IL = 1 - (2 * sqrtRatio / (1 + priceRatio))
        // But we want positive IL, so: IL = (2 * sqrtRatio / (1 + priceRatio)) - 1 (negative)
        // Actually: IL = (2*sqrt(k) / (1+k)) - 1 where k = priceRatio
        // This gives negative value, so we take absolute

        uint256 numerator = 2 * sqrtRatio * 1e18;
        uint256 denominator = (1e18 + priceRatio);

        // Result is in 1e18 scale, convert to bps
        uint256 il18 = (numerator * 1e18) / denominator;
        if (il18 > 1e18) {
            ilBps = ((il18 - 1e18) * 10000) / 1e18;
        } else {
            ilBps = ((1e18 - il18) * 10000) / 1e18;
        }

        // Adjust for partial removal (pro-rata)
        if (exitLiquidity < entryLiquidity) {
            ilBps = (ilBps * exitLiquidity) / entryLiquidity;
        }

        return ilBps;
    }

    /**
     * @notice Compute live risk profile for an active position
     * @param currentPrice Current TWAP price
     * @param entryPrice Entry TWAP price
     * @param timeElapsed Seconds since entry
     * @param poolVol Annualized volatility (bps)
     */
    function computeRiskProfile(
        uint256 currentPrice,
        uint256 entryPrice,
        uint256 timeElapsed,
        uint256 poolVol
    ) external pure returns (RiskProfile memory) {
        uint256 ilNow = _computeILNow(currentPrice, entryPrice);

        // Max IL approaches 100% as price → 0 or ∞
        uint256 maxLossBps = 10000;

        // Delta sensitivity: higher near current price, lower at extremes
        // Approximation: sensitivity = 1 / sqrt(priceRatio)
        uint256 priceRatio = (currentPrice * 1e18) / entryPrice;
        uint256 deltaSensitivity = 1e18 / _sqrt(priceRatio);

        // Time decay: longer held = more accumulated risk
        // Simplified: linear decay factor
        uint256 timeDecay = (timeElapsed * 100) / (30 days); // 100% at 30 days

        return RiskProfile({
            ilExposureBps: ilNow,
            maxLossBps: maxLossBps,
            deltaSensitivity: deltaSensitivity,
            timeDecay: timeDecay > 100 ? 100 : timeDecay
        });
    }

    /**
     * @notice Calculate risk token value for secondary trading
     * @param riskProfile Current risk metrics
     * @param coverageTier Tier determines max payout
     * @param premiumRate Current market premium rate
     */
    function priceRiskToken(
        RiskProfile memory riskProfile,
        uint8 coverageTier,
        uint256 premiumRate
    ) external pure returns (uint256) {
        // Risk token value = expected payout probability * max payout * liquidity
        // Simplified: use IL exposure as proxy for expected payout

        uint256 expectedIl = riskProfile.ilExposureBps;
        uint256 maxPayout = coverageTier == 0 ? 5000 : coverageTier == 1 ? 7500 : 10000;

        // Value = expected IL * max payout ratio * premium adjustment
        uint256 baseValue = (expectedIl * maxPayout * 1e18) / (10000 * 10000);
        uint256 premiumAdjustment = (premiumRate * 1e18) / 10000;

        return (baseValue * premiumAdjustment) / 1e18;
    }

    // ============ Internal Math ============

    function _computeILNow(uint256 currentPrice, uint256 entryPrice) internal pure returns (uint256) {
        if (entryPrice == 0) return 0;
        uint256 priceRatio = (currentPrice * 1e18) / entryPrice;
        uint256 sqrtRatio = _sqrt(priceRatio);
        uint256 il18 = (2 * sqrtRatio * 1e18) / (1e18 + priceRatio);
        if (il18 > 1e18) {
            return ((il18 - 1e18) * 10000) / 1e18;
        } else {
            return ((1e18 - il18) * 10000) / 1e18;
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}