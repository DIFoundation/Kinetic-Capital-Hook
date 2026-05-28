// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title VolatilityOracle
 * @notice Classifies market regimes and provides TWAP pricing
 */
contract VolatilityOracle {
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============

    uint8 public constant REGIME_CALM = 0;
    uint8 public constant REGIME_NORMAL = 1;
    uint8 public constant REGIME_ELEVATED = 2;
    uint8 public constant REGIME_EXTREME = 3;

    uint256 constant VOL_WINDOW = 1 hours; // Lookback window for vol calculation

    // ============ Structs ============

    struct PriceObservation {
        uint256 timestamp;
        uint256 price; // Q96.96
    }

    struct VolatilityState {
        uint256 lastPrice;
        uint256 lastTimestamp;
        uint256 cumulativeVol; // Accumulated volatility measure
        uint256 observationCount;
        uint8 currentRegime;
    }

    // ============ State ============

    mapping(PoolId => VolatilityState) public volStates;
    mapping(PoolId => PriceObservation[]) public priceHistory;

    // Regime thresholds (annualized volatility in bps)
    uint256 public calmThreshold = 500;      // < 5% annualized
    uint256 public normalThreshold = 1500;   // < 15%
    uint256 public elevatedThreshold = 4000; // < 40%

    // Multipliers for premium pricing
    mapping(uint8 => uint256) public regimeMultipliers;

    // ============ Events ============

    event RegimeChanged(PoolId indexed poolId, uint8 oldRegime, uint8 newRegime, uint256 vol);

    // ============ Constructor ============

    constructor() {
        regimeMultipliers[REGIME_CALM] = 100;      // 1.0x
        regimeMultipliers[REGIME_NORMAL] = 150;    // 1.5x
        regimeMultipliers[REGIME_ELEVATED] = 250;  // 2.5x
        regimeMultipliers[REGIME_EXTREME] = 400;    // 4.0x
    }

    // ============ Core Functions ============

    /**
     * @notice Record a new price observation and update volatility
     * @dev Called by hook afterSwap
     */
    function recordObservation(PoolId poolId, uint256 price) external {
        VolatilityState storage state = volStates[poolId];

        if (state.lastTimestamp > 0) {
            uint256 timeDelta = block.timestamp - state.lastTimestamp;
            if (timeDelta > 0) {
                uint256 priceDelta = price > state.lastPrice ? price - state.lastPrice : state.lastPrice - price;
                uint256 returnVol = (priceDelta * 1e18) / state.lastPrice;

                // Annualize: return * sqrt(365 * 24 * 3600 / timeDelta)
                uint256 annualizationFactor = _sqrt((365 days * 1e18) / timeDelta);
                uint256 annualizedVol = (returnVol * annualizationFactor) / 1e18;

                // Update cumulative (exponential moving average)
                state.cumulativeVol = (state.cumulativeVol * 95 + annualizedVol * 5) / 100;
                state.observationCount++;
            }
        }

        state.lastPrice = price;
        state.lastTimestamp = block.timestamp;

        // Store in history (circular buffer in production)
        priceHistory[poolId].push(PriceObservation({
            timestamp: block.timestamp,
            price: price
        }));

        // Check for regime change
        _updateRegime(poolId);
    }

    /**
     * @notice Classify current market regime for a pool
     * @return regime Current regime (0-3)
     * @return multiplier Premium multiplier for this regime (bps)
     */
    function classifyRegime(PoolId poolId) external view returns (uint8 regime, uint256 multiplier) {
        VolatilityState memory state = volStates[poolId];
        regime = state.currentRegime;
        multiplier = regimeMultipliers[regime];
    }

    /**
     * @notice Get TWAP price for a pool
     * @param key PoolKey
     * @param twapWindow Seconds to average over
     */
    function getTWAP(PoolKey calldata key, uint32 twapWindow) external view returns (uint256) {
        PoolId poolId = key.toId();
        PriceObservation[] storage history = priceHistory[poolId];

        if (history.length == 0) return 0;

        uint256 cutoff = block.timestamp - twapWindow;
        uint256 sumPrices;
        uint256 count;

        // Simple TWAP: average of observations in window
        // Production: use geometric TWAP or v4's built-in oracle
        for (uint256 i = history.length; i > 0; i--) {
            if (history[i - 1].timestamp < cutoff) break;
            sumPrices += history[i - 1].price;
            count++;
        }

        return count > 0 ? sumPrices / count : history[history.length - 1].price;
    }

    /**
     * @notice Update risk token pricing based on regime
     * @dev Called by hook to reprice active risk
     */
    function updateRiskPricing(PoolId poolId, uint8 newRegime) external {
        // In production: update a pricing feed or checkpoint system
        // Simplified: regime change is the pricing signal
        volStates[poolId].currentRegime = newRegime;
    }

    // ============ Admin ============

    function setThresholds(uint256 calm, uint256 normal, uint256 elevated) external {
        // Add access control
        calmThreshold = calm;
        normalThreshold = normal;
        elevatedThreshold = elevated;
    }

    // ============ Internal ============

    function _updateRegime(PoolId poolId) internal {
        VolatilityState storage state = volStates[poolId];
        uint256 vol = state.cumulativeVol;
        uint8 oldRegime = state.currentRegime;
        uint8 newRegime;

        if (vol < calmThreshold) {
            newRegime = REGIME_CALM;
        } else if (vol < normalThreshold) {
            newRegime = REGIME_NORMAL;
        } else if (vol < elevatedThreshold) {
            newRegime = REGIME_ELEVATED;
        } else {
            newRegime = REGIME_EXTREME;
        }

        if (newRegime != oldRegime) {
            state.currentRegime = newRegime;
            emit RegimeChanged(poolId, oldRegime, newRegime, vol);
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

    // ============ Views ============

    function getCurrentVolatility(PoolId poolId) external view returns (uint256) {
        return volStates[poolId].cumulativeVol;
    }

    function getRegimeMultiplier(uint8 regime) external view returns (uint256) {
        return regimeMultipliers[regime];
    }
}