// SPDX-License-Identifier: MIT
// contracts/src/interfaces/INegRiskAdapter.sol
pragma solidity ^0.8.24;

/// @title INegRiskAdapter
/// @notice Minimal interface for Polymarket's NegRiskAdapter
/// @dev NegRiskAdapter on Polygon: 0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296
interface INegRiskAdapter {
    function redeemPositions(bytes32 conditionId, uint256[] calldata amounts) external;
}
