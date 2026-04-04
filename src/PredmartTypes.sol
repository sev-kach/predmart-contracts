// SPDX-License-Identifier: MIT
// contracts/src/PredmartTypes.sol
pragma solidity ^0.8.24;

/// @notice Shared type definitions for PredmartLendingPool and PredmartPoolExtension.
///         Both contracts use delegatecall and share storage — struct layouts MUST be identical.
///         This file is the single source of truth for all shared types.

/*//////////////////////////////////////////////////////////////
                           STRUCTS
//////////////////////////////////////////////////////////////*/

struct Position {
    uint256 collateralAmount; // ERC-1155 shares deposited
    uint256 borrowShares;     // Shares of the global borrow pool owned by this position
    uint256 lastDepositTimestamp; // DEPRECATED — kept for storage layout compatibility
    uint256 borrowedPrincipal;   // v0.9.1 — cumulative USDC principal borrowed (for accurate per-token cap tracking)
}

struct MarketResolution {
    bool resolved;
    bool won;
}

struct Redemption {
    bool redeemed;
    uint256 totalShares;  // Total CTF shares redeemed
    uint256 usdcReceived; // Actual USDC received from CTF
}

struct PendingClose {
    address surplusRecipient; // Where surplus USDC goes after settlement (from CloseAuth.allowedTo)
    uint256 debtAmount;       // USDC owed back to pool (6 decimals)
    uint256 collateralAmount; // Shares sent to relayer (for event tracking)
    uint256 deadline;         // block.timestamp + CLOSE_TIMEOUT
}

/*//////////////////////////////////////////////////////////////
                        SHARED ERRORS
//////////////////////////////////////////////////////////////*/

error NotAdmin();
error InvalidAddress();
error NoPosition();
error TimelockNotReady();
error NoPendingChange();
error NotRelayer();

/*//////////////////////////////////////////////////////////////
                        SHARED EVENTS
//////////////////////////////////////////////////////////////*/

event BadDebtAbsorbed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
event InterestAccrued(uint256 interest, uint256 reserve);
event PositionCloseInitiated(address indexed borrower, uint256 indexed tokenId, uint256 debtAmount, uint256 collateralAmount);
event OperationFeeCollected(address indexed payer, uint256 amount);
event OperationFeeUpdated(uint256 newFee);
