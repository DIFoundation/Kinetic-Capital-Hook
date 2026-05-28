// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

// ============ IRiskEngine ============

interface IRiskEngine {
    struct RiskProfile {
        uint256 ilExposureBps;
        uint256 maxLossBps;
        uint256 deltaSensitivity;
        uint256 timeDecay;
    }

    function computeIL(
        uint256 entryPrice,
        uint256 exitPrice,
        uint256 entryLiquidity,
        uint256 exitLiquidity
    ) external pure returns (uint256 ilBps);

    function computeRiskProfile(
        uint256 currentPrice,
        uint256 entryPrice,
        uint256 timeElapsed,
        uint256 poolVol
    ) external pure returns (RiskProfile memory);

    function priceRiskToken(
        RiskProfile memory riskProfile,
        uint8 coverageTier,
        uint256 premiumRate
    ) external pure returns (uint256);
}

// ============ IYieldVault ============

interface IYieldVault {
    function deposit(uint256 amount, address currency) external;
    function settleClaim(uint256 claimAmount, address currency, address recipient) external returns (uint256);
    function withdraw(uint256 amount, address currency, address recipient) external returns (uint256);
    function distributeYield(uint256 amount, address currency) external;
    function getUserShare(uint256 principal) external view returns (uint256);
    function getSolvencyRatio() external view returns (uint256);
}

// ============ IVolatilityOracle ============

interface IVolatilityOracle {
    function recordObservation(PoolId poolId, uint256 price) external;
    function classifyRegime(PoolId poolId) external view returns (uint8 regime, uint256 multiplier);
    function getTWAP(PoolKey calldata key, uint32 twapWindow) external view returns (uint256);
    function updateRiskPricing(PoolId poolId, uint8 newRegime) external;
    function getCurrentVolatility(PoolId poolId) external view returns (uint256);
}

// ============ IRiskToken ============

interface IRiskToken {
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function setExposureCap(uint256 id, uint256 cap) external;
    function setRiskMetadata(uint256 id, bytes calldata metadata) external;
    function markSettled(uint256 id) external;
}