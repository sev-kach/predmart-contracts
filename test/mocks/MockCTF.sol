// SPDX-License-Identifier: MIT
// contracts/test/mocks/MockCTF.sol
pragma solidity ^0.8.24;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { MockUSDC } from "./MockUSDC.sol";

/// @notice Mock Conditional Token Framework for testing — public mint + redeemPositions
contract MockCTF is ERC1155 {
    /// @dev conditionId → tokenId mapping (configured per test)
    mapping(bytes32 => uint256) public conditionToToken;
    address public usdcToken;

    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    /// @notice Configure the mock for redemption tests
    /// @param conditionId The conditionId that maps to a tokenId
    /// @param tokenId The ERC-1155 token ID to redeem
    /// @param _usdc Address of MockUSDC (used to mint USDC on redemption)
    function configureRedemption(bytes32 conditionId, uint256 tokenId, address _usdc) external {
        conditionToToken[conditionId] = tokenId;
        usdcToken = _usdc;
    }

    /// @notice Mock redeemPositions: burns all caller's shares of the mapped tokenId, mints equivalent USDC
    /// @dev Won market: 1 CTF share = $1 USDC (1e6 USDC per 1e6 shares)
    function redeemPositions(address, bytes32, bytes32 conditionId, uint256[] calldata) external {
        uint256 tokenId = conditionToToken[conditionId];
        uint256 balance = balanceOf(msg.sender, tokenId);
        require(balance > 0, "No shares to redeem");
        _burn(msg.sender, tokenId, balance);
        MockUSDC(usdcToken).mint(msg.sender, balance); // 1:1 share → USDC
    }
}
