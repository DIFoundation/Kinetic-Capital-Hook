// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC6909} from "v4-core/src/ERC6909.sol";

/**
 * @title RiskToken
 * @notice ERC-6909 multi-token representing fractional impermanent loss exposure
 * @dev Each token ID corresponds to a specific pool/position risk slice
 */
contract RiskToken is ERC6909 {
    // ============ State ============

    // tokenId => metadata about the risk exposure
    mapping(uint256 => RiskMetadata) public riskMetadata;

    // tokenId => total supply cap (exposure limit)
    mapping(uint256 => uint256) public exposureCaps;

    // tokenId => current exposure amount
    mapping(uint256 => uint256) public currentExposure;

    struct RiskMetadata {
        bytes32 positionKey;
        PoolId poolId;
        uint256 entryPrice;
        uint256 coverageTier;
        uint256 maxPayoutBps;
        bool settled;
    }

    // ============ Events ============

    event RiskTokenMinted(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event RiskTokenBurned(uint256 indexed tokenId, address indexed owner, uint256 amount);
    event RiskTokenTransferred(uint256 indexed tokenId, address indexed from, address indexed to, uint256 amount);
    event ExposureCapSet(uint256 indexed tokenId, uint256 cap);

    // ============ Errors ============

    error ExposureCapExceeded();
    error TokenSettled();
    error Unauthorized();

    // ============ Modifiers ============

    modifier onlyHook() {
        // In production: restrict to KineticCapitalHook
        _;
    }

    // ============ Core Functions ============

    /**
     * @notice Mint risk tokens representing IL exposure
     * @param to Recipient (LP or counterparty)
     * @param id Token ID (derived from position)
     * @param amount Liquidity amount / exposure units
     */
    function mint(address to, uint256 id, uint256 amount) external onlyHook {
        if (currentExposure[id] + amount > exposureCaps[id]) revert ExposureCapExceeded();

        _mint(to, id, amount);
        currentExposure[id] += amount;

        emit RiskTokenMinted(id, to, amount);
    }

    /**
     * @notice Burn risk tokens on settlement or trade reversal
     * @param from Token holder
     * @param id Token ID
     * @param amount Amount to burn
     */
    function burn(address from, uint256 id, uint256 amount) external onlyHook {
        _burn(from, id, amount);
        currentExposure[id] -= amount;

        emit RiskTokenBurned(id, from, amount);
    }

    /**
     * @notice Override transfer to track exposure movement
     * @dev When risk token trades, IL exposure transfers to buyer
     */
    function transfer(address receiver, uint256 id, uint256 amount) public override returns (bool) {
        bool success = super.transfer(receiver, id, amount);

        if (success) {
            emit RiskTokenTransferred(id, msg.sender, receiver, amount);
        }

        return success;
    }

    /**
     * @notice Set exposure cap for a risk token
     * @param id Token ID
     * @param cap Maximum exposure allowed
     */
    function setExposureCap(uint256 id, uint256 cap) external onlyHook {
        exposureCaps[id] = cap;
        emit ExposureCapSet(id, cap);
    }

    /**
     * @notice Get risk metadata for a token
     */
    function getRiskMetadata(uint256 id) external view returns (RiskMetadata memory) {
        return riskMetadata[id];
    }

    /**
     * @notice Set risk metadata (called by hook on position open)
     */
    function setRiskMetadata(uint256 id, RiskMetadata calldata metadata) external onlyHook {
        riskMetadata[id] = metadata;
    }

    /**
     * @notice Mark token as settled (post-IL settlement)
     */
    function markSettled(uint256 id) external onlyHook {
        riskMetadata[id].settled = true;
    }
}

// Need to import this or define it
type PoolId is bytes32;