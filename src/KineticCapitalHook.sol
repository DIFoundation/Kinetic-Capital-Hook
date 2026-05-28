// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

import {IRiskEngine, IYieldVault, IVolatilityOracle, IRiskToken} from "./interfaces/IHook.sol";

/**
 * @title KineticCapitalHook
 * @notice Uniswap v4 hook that decomposes LP positions into yield, risk, and protection layers
 * @dev Intercepts beforeAddLiquidity, afterRemoveLiquidity, and afterSwap
 */
contract KineticCapitalHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    // ============ Structs ============

    struct Position {
        uint256 entryTimestamp;
        uint256 entryPrice;      // TWAP price at entry (Q96.96)
        uint256 liquidityAmount;
        uint256 premiumPaid;
        uint8 coverageTier;      // 0=Basic, 1=Standard, 2=Full
        uint256 riskTokenId;     // ERC-6909 token ID for this position's risk
        uint256 yieldTokenId;    // ERC-6909 token ID for this position's yield
        bool active;
    }

    struct PoolConfig {
        bool enabled;
        uint32 twapWindow;       // Seconds for TWAP (default 1800 = 30 min)
        uint256 baseRateBps;     // Base premium rate in basis points
        address riskEngine;
        address yieldVault;
        address volatilityOracle;
        address riskToken;
    }

    // ============ State ============

    IRiskEngine public riskEngine;
    IYieldVault public yieldVault;
    IVolatilityOracle public volatilityOracle;
    IRiskToken public riskToken;

    // poolId => config
    mapping(PoolId => PoolConfig) public poolConfigs;

    // position key (owner + poolId + nonce) => Position
    mapping(bytes32 => Position) public positions;

    // poolId => cumulative volatility accumulator (updated per swap)
    mapping(PoolId => uint256) public volAccumulators;

    // Nonce counter for position uniqueness
    mapping(address => uint256) public userNonce;

    // Coverage tier constants
    uint8 public constant TIER_BASIC = 0;
    uint8 public constant TIER_STANDARD = 1;
    uint8 public constant TIER_FULL = 2;

    // Tier configs: (thresholdBps, maxPayoutBps, premiumMultiplier)
    mapping(uint8 => uint256) public tierThresholdBps;
    mapping(uint8 => uint256) public tierMaxPayoutBps;
    mapping(uint8 => uint256) public tierPremiumMultiplier;

    // ============ Events ============

    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed owner,
        PoolId indexed poolId,
        uint256 liquidity,
        uint256 premium,
        uint8 tier,
        uint256 riskTokenId,
        uint256 yieldTokenId
    );

    event PositionClosed(
        bytes32 indexed positionKey,
        address indexed owner,
        PoolId indexed poolId,
        uint256 realizedIlBps,
        uint256 payout,
        uint256 premiumRefund
    );

    event RiskTokenTraded(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 amount,
        uint256 price
    );

    event RegimeUpdated(PoolId indexed poolId, uint8 regime);

    // ============ Errors ============

    error PoolNotEnabled();
    error PositionNotFound();
    error PositionActive();
    error InvalidCoverageTier();
    error InsufficientPremium();
    error PremiumTransferFailed();
    error SettlementFailed();
    error Unauthorized();

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        address _riskEngine,
        address _yieldVault,
        address _volatilityOracle,
        address _riskToken
    ) BaseHook(_poolManager) {
        riskEngine = IRiskEngine(_riskEngine);
        yieldVault = IYieldVault(_yieldVault);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
        riskToken = IRiskToken(_riskToken);

        // Initialize tier configs
        tierThresholdBps[TIER_BASIC] = 500;      // 5%
        tierMaxPayoutBps[TIER_BASIC] = 5000;     // 50% of IL
        tierPremiumMultiplier[TIER_BASIC] = 50;    // 0.5x = 50 bps

        tierThresholdBps[TIER_STANDARD] = 300;     // 3%
        tierMaxPayoutBps[TIER_STANDARD] = 7500;    // 75% of IL
        tierPremiumMultiplier[TIER_STANDARD] = 100; // 1.0x = 100 bps

        tierThresholdBps[TIER_FULL] = 100;         // 1%
        tierMaxPayoutBps[TIER_FULL] = 10000;       // 100% of IL
        tierPremiumMultiplier[TIER_FULL] = 200;   // 2.0x = 200 bps
    }

    // ============ Hook Permissions ============

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,   // Capture entry price, mint tokens, collect premium
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // Compute IL, trigger payout/refund
            beforeSwap: false,
            afterSwap: true,            // Update vol accumulator, reprice risk
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Admin Functions ============

    function configurePool(
        PoolKey calldata key,
        bool enabled,
        uint32 twapWindow,
        uint256 baseRateBps
    ) external {
        // In production, add access control (onlyOwner / governance)
        PoolId poolId = key.toId();
        poolConfigs[poolId] = PoolConfig({
            enabled: enabled,
            twapWindow: twapWindow,
            baseRateBps: baseRateBps,
            riskEngine: address(riskEngine),
            yieldVault: address(yieldVault),
            volatilityOracle: address(volatilityOracle),
            riskToken: address(riskToken)
        });
    }

    // ============ Core Hook: beforeAddLiquidity ============

    /**
     * @notice Intercepts LP deposits to decompose position into layers
     * @dev Mints RISK-TOKEN and YIELD-CLAIM-TOKEN, collects premium, records entry
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        PoolId poolId = key.toId();
        PoolConfig memory config = poolConfigs[poolId];

        if (!config.enabled) revert PoolNotEnabled();

        // Decode hookData: (uint8 coverageTier)
        uint8 coverageTier = abi.decode(hookData, (uint8));
        if (coverageTier > TIER_FULL) revert InvalidCoverageTier();

        // Get current TWAP price for entry baseline
        uint256 entryPrice = _getTWAPPrice(key, config.twapWindow);

        // Classify market regime
        (uint8 regime, uint256 volMultiplier) = volatilityOracle.classifyRegime(poolId);

        // Calculate premium
        uint256 positionValue = _estimatePositionValue(key, params);
        uint256 premium = _calculatePremium(positionValue, coverageTier, volMultiplier, config.baseRateBps);

        // Transfer premium from LP to vault (using v4's flash accounting)
        // Premium is paid in Currency0 (simplified; production would handle both)
        Currency premiumCurrency = key.currency0;
        _collectPremium(sender, premium, premiumCurrency);

        // Generate unique position key
        uint256 nonce = userNonce[sender]++;
        bytes32 positionKey = keccak256(abi.encodePacked(sender, poolId, nonce));

        // Mint risk and yield tokens (ERC-6909 via PoolManager)
        uint256 riskTokenId = uint256(keccak256(abi.encodePacked(positionKey, "RISK")));
        uint256 yieldTokenId = uint256(keccak256(abi.encodePacked(positionKey, "YIELD")));

        // Mint tokens to LP via PoolManager's ERC-6909 accounting
        poolManager.mint(address(riskToken), riskTokenId, params.liquidityDelta);
        poolManager.mint(address(this), yieldTokenId, params.liquidityDelta);

        // Record position
        positions[positionKey] = Position({
            entryTimestamp: block.timestamp,
            entryPrice: entryPrice,
            liquidityAmount: uint256(params.liquidityDelta),
            premiumPaid: premium,
            coverageTier: coverageTier,
            riskTokenId: riskTokenId,
            yieldTokenId: yieldTokenId,
            active: true
        });

        // Forward premium to yield vault for compounding
        yieldVault.deposit(premium, premiumCurrency);

        emit PositionOpened(positionKey, sender, poolId, uint256(params.liquidityDelta), premium, coverageTier, riskTokenId, yieldTokenId);
        emit RegimeUpdated(poolId, regime);

        return this.beforeAddLiquidity.selector;
    }

    // ============ Core Hook: afterRemoveLiquidity ============

    /**
     * @notice Intercepts LP withdrawals to compute IL and settle claims
     * @dev Computes realized IL, compares against threshold, pays claim or refunds premium
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Decode hookData: (bytes32 positionKey)
        bytes32 positionKey = abi.decode(hookData, (bytes32));
        Position memory pos = positions[positionKey];

        if (!pos.active) revert PositionNotFound();

        // Compute exit TWAP price
        PoolConfig memory config = poolConfigs[poolId];
        uint256 exitPrice = _getTWAPPrice(key, config.twapWindow);

        // Calculate realized IL in basis points
        uint256 realizedIlBps = riskEngine.computeIL(
            pos.entryPrice,
            exitPrice,
            pos.liquidityAmount,
            uint256(-params.liquidityDelta)
        );

        uint256 payout = 0;
        uint256 premiumRefund = 0;

        // Determine settlement outcome
        uint256 threshold = tierThresholdBps[pos.coverageTier];
        uint256 maxPayout = tierMaxPayoutBps[pos.coverageTier];

        if (realizedIlBps > threshold) {
            // IL exceeds threshold: vault pays claim
            uint256 ilAmount = (pos.liquidityAmount * realizedIlBps) / 10000;
            uint256 coveredIl = (ilAmount * maxPayout) / 10000;
            payout = yieldVault.settleClaim(coveredIl, key.currency0, sender);
        } else {
            // IL below threshold: refund unused premium + accrued yield
            uint256 vaultShare = yieldVault.getUserShare(pos.premiumPaid);
            premiumRefund = vaultShare > pos.premiumPaid ? vaultShare : pos.premiumPaid;
            yieldVault.withdraw(premiumRefund, key.currency0, sender);
        }

        // Burn risk and yield tokens
        riskToken.burn(sender, pos.riskTokenId, pos.liquidityAmount);
        poolManager.burn(address(this), pos.yieldTokenId, pos.liquidityAmount);

        // Mark position inactive
        positions[positionKey].active = false;

        // Distribute swap fees accumulated to yield token holder
        _distributeYield(positionKey, sender, delta);

        emit PositionClosed(positionKey, sender, poolId, realizedIlBps, payout, premiumRefund);

        return (this.afterRemoveLiquidity.selector, delta);
    }

    // ============ Core Hook: afterSwap ============

    /**
     * @notice Updates volatility accumulator and reprices risk tokens post-swap
     * @dev Drives dynamic premium pricing for future deposits
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Update volatility accumulator
        uint256 priceMove = _extractPriceMove(delta, params);
        volAccumulators[poolId] += priceMove;

        // Check if regime shift occurred
        (uint8 newRegime, ) = volatilityOracle.classifyRegime(poolId);

        // Reprice active risk tokens for this pool
        _repriceRiskTokens(poolId, newRegime);

        emit RegimeUpdated(poolId, newRegime);

        return (this.afterSwap.selector, 0);
    }

    // ============ Risk Token Trading ============

    /**
     * @notice Allow LPs to sell their RISK-TOKEN to a counterparty
     * @dev Transfers IL exposure; seller loses coverage, buyer gains it
     */
    function tradeRiskToken(
        uint256 riskTokenId,
        address buyer,
        uint256 amount,
        uint256 price
    ) external {
        // In production: add proper escrow, slippage protection, fees
        address seller = msg.sender;

        // Transfer risk token
        riskToken.transferFrom(seller, buyer, riskTokenId, amount);

        // Update position tracking (simplified; production needs position registry)
        // Buyer now holds the IL exposure for this slice

        emit RiskTokenTraded(riskTokenId, seller, buyer, amount, price);
    }

    // ============ Internal Helpers ============

    function _getTWAPPrice(PoolKey memory key, uint32 twapWindow) internal view returns (uint256) {
        // Use v4's internal TWAP or external oracle
        // Simplified: call PoolManager's observe function
        // Production: implement proper oracle with cardinality checks
        return volatilityOracle.getTWAP(key, twapWindow);
    }

    function _estimatePositionValue(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal view returns (uint256) {
        // Simplified estimation using current pool reserves
        // Production: more sophisticated valuation
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 192);

        // Rough USD value estimate (assuming currency0 is priced in currency1 terms)
        uint256 liquidity = uint256(params.liquidityDelta > 0 ? params.liquidityDelta : -params.liquidityDelta);
        return liquidity * price / 1e18; // Simplified
    }

    function _calculatePremium(
        uint256 positionValue,
        uint8 coverageTier,
        uint256 volMultiplier,
        uint256 baseRateBps
    ) internal view returns (uint256) {
        uint256 tierMult = tierPremiumMultiplier[coverageTier];
        uint256 positionSizeFactor = _getPositionSizeFactor(positionValue);

        // Premium = value * baseRate * volMult * tierMult * sizeFactor / (10000 * 100 * 100)
        // Simplified: all multipliers in bps
        uint256 premium = positionValue * baseRateBps * volMultiplier * tierMult * positionSizeFactor;
        premium = premium / (10000 * 100 * 100 * 100); // Normalize

        return premium;
    }

    function _getPositionSizeFactor(uint256 value) internal pure returns (uint256) {
        if (value < 10_000e18) return 100;      // 1.0x = 100 bps
        if (value < 100_000e18) return 90;      // 0.9x
        return 80;                               // 0.8x
    }

    function _collectPremium(address from, uint256 amount, Currency currency) internal {
        // Use v4's flash accounting: take from user's v4 balance
        // In production: handle ERC20 transfers, approvals, etc.
        // Simplified: assume user has approved PoolManager
    }

    function _distributeYield(
        bytes32 positionKey,
        address recipient,
        BalanceDelta delta
    ) internal {
        // Extract earned fees from delta and send to yield vault for distribution
        // YIELD-CLAIM-TOKEN holders claim from vault
        uint256 fee0 = uint256(int256(delta.amount0()) > 0 ? int256(delta.amount0()) : 0);
        uint256 fee1 = uint256(int256(delta.amount1()) > 0 ? int256(delta.amount1()) : 0);

        if (fee0 > 0) yieldVault.distributeYield(fee0, Currency.unwrap(poolConfigs[PoolId.wrap(0)].enabled ? Currency.wrap(0) : Currency.wrap(0))); // Simplified
        if (fee1 > 0) yieldVault.distributeYield(fee1, Currency.unwrap(poolConfigs[PoolId.wrap(0)].enabled ? Currency.wrap(0) : Currency.wrap(0)));
    }

    function _extractPriceMove(
        BalanceDelta delta,
        IPoolManager.SwapParams memory params
    ) internal pure returns (uint256) {
        // Calculate absolute price movement from swap delta
        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);
        return amountSpecified;
    }

    function _repriceRiskTokens(PoolId poolId, uint8 regime) internal {
        // Update risk token valuations based on new regime
        // Production: iterate active positions or use checkpoint system
        volatilityOracle.updateRiskPricing(poolId, regime);
    }

    // ============ View Functions ============

    function getPosition(bytes32 positionKey) external view returns (Position memory) {
        return positions[positionKey];
    }

    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return poolConfigs[poolId];
    }

    function getTierConfig(uint8 tier) external view returns (uint256 threshold, uint256 maxPayout, uint256 premiumMult) {
        return (tierThresholdBps[tier], tierMaxPayoutBps[tier], tierPremiumMultiplier[tier]);
    }
}