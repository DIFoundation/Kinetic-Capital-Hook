// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldVault} from "./interfaces/IHook.sol";

/**
 * @title YieldVault
 * @notice ERC-4626 vault that compounds LP premiums and backs IL insurance claims
 * @dev Integrates with Aave/Morpho for yield generation
 */
contract YieldVault is ERC4626, ReentrancyGuard, IYieldVault {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant SOLVENCY_TARGET = 11000; // 110% in bps
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ State ============

    // Total outstanding coverage liability
    uint256 public totalCoverage;

    // Premium deposits mapped to original depositor (for refund tracking)
    mapping(address => uint256) public userPrincipal;
    mapping(address => uint256) public userShareSnapshot;

    // External yield strategy (Aave/Morpho integration)
    address public yieldStrategy;
    address public admin;

    // Emergency controls
    bool public paused;
    uint256 public coverageCap;

    // ============ Events ============

    event PremiumDeposited(address indexed lp, uint256 amount, uint256 shares);
    event ClaimSettled(address indexed lp, uint256 amount, uint256 ilCovered);
    event PremiumRefunded(address indexed lp, uint256 amount, uint256 yieldEarned);
    event YieldDistributed(uint256 amount);
    event SolvencyWarning(uint256 ratio);
    event EmergencyPauseTriggered();

    // ============ Errors ============

    error InsufficientSolvency();
    error VaultPaused();
    error Unauthorized();
    error ZeroDeposit();
    error ClaimExceedsCoverage();

    // ============ Constructor ============

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address _yieldStrategy
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        yieldStrategy = _yieldStrategy;
        admin = msg.sender;
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit premium from LP into vault
     * @param amount Premium amount in asset tokens
     * @param currency Currency identifier (for multi-currency support)
     */
    function deposit(uint256 amount, address currency) external nonReentrant {
        if (paused) revert VaultPaused();
        if (amount == 0) revert ZeroDeposit();

        // Transfer asset from hook
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);

        // Mint vault shares to the hook (representing LP's claim)
        uint256 shares = previewDeposit(amount);
        _mint(msg.sender, shares);

        // Track principal for refund calculations
        userPrincipal[msg.sender] += amount;
        userShareSnapshot[msg.sender] += shares;

        // Deploy to external yield strategy (Aave/Morpho)
        if (yieldStrategy != address(0)) {
            IERC20(currency).approve(yieldStrategy, amount);
            // IYieldStrategy(yieldStrategy).deposit(amount); // Interface call
        }

        totalCoverage += amount;

        _checkSolvency();

        emit PremiumDeposited(msg.sender, amount, shares);
    }

    /**
     * @notice Settle IL claim to LP on exit
     * @param claimAmount Amount of IL to cover
     * @param currency Asset to pay out
     * @param recipient LP receiving payout
     * @return actualPayout Amount actually paid (may be pro-rata if undercollateralized)
     */
    function settleClaim(
        uint256 claimAmount,
        address currency,
        address recipient
    ) external nonReentrant returns (uint256 actualPayout) {
        if (paused) revert VaultPaused();

        uint256 vaultAssets = totalAssets();
        uint256 maxPayout = (vaultAssets * tierMaxPayoutBps(1)) / BPS_DENOMINATOR; // Standard tier default

        // Pro-rata if insufficient
        if (claimAmount > maxPayout) {
            actualPayout = maxPayout;
        } else {
            actualPayout = claimAmount;
        }

        if (actualPayout > vaultAssets) {
            actualPayout = vaultAssets; // Last resort cap
        }

        // Burn shares from hook's balance (representing coverage consumption)
        uint256 sharesToBurn = previewWithdraw(actualPayout);
        _burn(msg.sender, sharesToBurn);

        // Transfer to LP
        IERC20(currency).safeTransfer(recipient, actualPayout);

        totalCoverage -= actualPayout;

        _checkSolvency();

        emit ClaimSettled(recipient, actualPayout, claimAmount);
    }

    /**
     * @notice Refund unused premium + accrued yield to LP
     * @param amount Amount to withdraw
     * @param currency Asset to withdraw
     * @param recipient LP receiving refund
     */
    function withdraw(
        uint256 amount,
        address currency,
        address recipient
    ) external nonReentrant returns (uint256) {
        if (paused) revert VaultPaused();

        uint256 shares = previewWithdraw(amount);
        _burn(msg.sender, shares);

        // Include yield earned since deposit
        uint256 principal = userPrincipal[msg.sender];
        uint256 yieldEarned = amount > principal ? amount - principal : 0;

        IERC20(currency).safeTransfer(recipient, amount);

        userPrincipal[msg.sender] = principal > amount ? principal - amount : 0;
        userShareSnapshot[msg.sender] = userShareSnapshot[msg.sender] > shares
            ? userShareSnapshot[msg.sender] - shares
            : 0;

        totalCoverage -= amount;

        emit PremiumRefunded(recipient, amount, yieldEarned);

        return amount;
    }

    /**
     * @notice Distribute swap fee yield to YIELD-CLAIM-TOKEN holders
     * @param amount Fee amount to distribute
     * @param currency Asset to distribute
     */
    function distributeYield(uint256 amount, address currency) external {
        // In production: track yield claims per YIELD-CLAIM-TOKEN
        // Simplified: add to vault assets, increasing share value
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldDistributed(amount);
    }

    /**
     * @notice Get user's current share value including yield
     * @param principal Original premium paid
     */
    function getUserShare(uint256 principal) external view returns (uint256) {
        uint256 totalVaultAssets = totalAssets();
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return principal;

        uint256 userShares = (principal * totalShares) / (totalVaultAssets - principal);
        return (userShares * totalVaultAssets) / totalShares;
    }

    // ============ Solvency Management ============

    function _checkSolvency() internal {
        uint256 ratio = getSolvencyRatio();

        if (ratio < SOLVENCY_TARGET && ratio >= BPS_DENOMINATOR) {
            emit SolvencyWarning(ratio);
        } else if (ratio < BPS_DENOMINATOR) {
            // Critical: undercollateralized
            paused = true;
            emit EmergencyPauseTriggered();
        }
    }

    function getSolvencyRatio() public view returns (uint256) {
        if (totalCoverage == 0) return SOLVENCY_TARGET;
        return (totalAssets() * BPS_DENOMINATOR) / totalCoverage;
    }

    // ============ Admin Functions ============

    function setYieldStrategy(address _strategy) external {
        if (msg.sender != admin) revert Unauthorized();
        yieldStrategy = _strategy;
    }

    function setCoverageCap(uint256 _cap) external {
        if (msg.sender != admin) revert Unauthorized();
        coverageCap = _cap;
    }

    function emergencyPause() external {
        if (msg.sender != admin) revert Unauthorized();
        paused = true;
        emit EmergencyPauseTriggered();
    }

    function emergencyUnpause() external {
        if (msg.sender != admin) revert Unauthorized();
        paused = false;
    }

    // ============ Helpers ============

    function tierMaxPayoutBps(uint8 tier) internal pure returns (uint256) {
        if (tier == 0) return 5000;
        if (tier == 1) return 7500;
        return 10000;
    }

    // Override totalAssets to include external strategy yield
    function totalAssets() public view override returns (uint256) {
        uint256 baseAssets = super.totalAssets();
        // In production: add yield strategy balance
        // baseAssets += IYieldStrategy(yieldStrategy).balanceOf(address(this));
        return baseAssets;
    }
}