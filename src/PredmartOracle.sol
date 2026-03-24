// SPDX-License-Identifier: MIT
// contracts/src/PredmartOracle.sol
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title PredmartOracle
/// @notice Library for verifying signed price data and market resolution data from the Predmart oracle
/// @dev Uses ecrecover to verify that price/resolution data was signed by the trusted oracle address
library PredmartOracle {
    /// @notice Signed price data from the oracle
    struct PriceData {
        uint256 tokenId;
        uint256 price; // WAD (1e18 = $1.00)
        uint256 timestamp;
        uint256 maxBorrow; // USDC (6 decimals) — depth-gate cap, signed by oracle
        bytes signature;
    }

    /// @notice Signed market resolution data from the oracle
    struct ResolutionData {
        uint256 tokenId;
        bool won;
        uint256 timestamp;
        bytes signature;
    }

    error PriceTooOld();
    error PriceTooHigh();
    error PriceFromFuture();
    error InvalidOracleSignature();
    error ResolutionTooOld();
    error ResolutionFromFuture();
    error TokenIdMismatch();

    /// @notice Verify a signed price and return the price value
    /// @param data Signed price data from the oracle
    /// @param oracle Trusted oracle signer address
    /// @param pool Contract address (binds signature to this deployment)
    /// @param maxAge Maximum allowed age of the price in seconds
    /// @return price The verified price in WAD
    function verifyPrice(
        PriceData calldata data,
        address oracle,
        address pool,
        uint256 maxAge
    ) internal view returns (uint256) {
        if (data.timestamp > block.timestamp) revert PriceFromFuture();
        if (block.timestamp - data.timestamp > maxAge) revert PriceTooOld();
        if (data.price > 1e18) revert PriceTooHigh();

        bytes32 hash = keccak256(abi.encodePacked(block.chainid, pool, data.tokenId, data.price, data.timestamp, data.maxBorrow));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        address signer = ECDSA.recover(ethHash, data.signature);
        if (signer != oracle) revert InvalidOracleSignature();

        return data.price;
    }

    /// @notice Verify a signed market resolution and return the outcome
    /// @param data Signed resolution data from the oracle
    /// @param oracle Trusted oracle signer address
    /// @param pool Contract address (binds signature to this deployment)
    /// @param maxAge Maximum allowed age of the resolution data in seconds
    /// @return won Whether the market resolved in favor of the token holders
    function verifyResolution(
        ResolutionData calldata data,
        address oracle,
        address pool,
        uint256 maxAge
    ) internal view returns (bool) {
        if (data.timestamp > block.timestamp) revert ResolutionFromFuture();
        if (block.timestamp - data.timestamp > maxAge) revert ResolutionTooOld();

        bytes32 hash = keccak256(abi.encodePacked("RESOLVE", block.chainid, pool, data.tokenId, data.won, data.timestamp));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        address signer = ECDSA.recover(ethHash, data.signature);
        if (signer != oracle) revert InvalidOracleSignature();

        return data.won;
    }
}
