// SPDX-License-Identifier: LicenseRef-PredMart-NC
// contracts/src/interfaces/ICTF.sol
pragma solidity ^0.8.24;

/// @title ICTF
/// @notice Minimal interface for Polymarket's Conditional Token Framework (ERC-1155)
/// @dev CTF contract on Polygon: 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045
interface ICTF {
    function balanceOf(address owner, uint256 id) external view returns (uint256);

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice Redeem resolved conditional tokens for collateral (USDC)
    /// @dev Burns all caller's tokens for the given condition and returns collateral for winning outcomes
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
}
