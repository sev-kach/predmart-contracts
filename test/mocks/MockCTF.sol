// SPDX-License-Identifier: MIT
// contracts/test/mocks/MockCTF.sol
pragma solidity ^0.8.24;

import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @notice Mock Conditional Token Framework for testing — public mint
contract MockCTF is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}
