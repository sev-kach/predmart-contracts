// src/PredmartLeverageModule.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/// @title PredmartLeverageModule
/// @notice Safe Module that pre-approves a LeverageAuth hash on the Safe so that
///         PredMart's `pullUsdcForLeverage` can call with empty `fromSignature`.
///
/// @dev    Why this exists: PredMart's `pullUsdcForLeverage(auth, authSig, fromSig, ...)`
///         requires the Safe (auth.allowedFrom) to consent to the USDC pull whenever
///         allowedFrom != borrower (always true for PredMart Safes). The Safe consents
///         by either (a) supplying an EIP-1271-validatable signature over the LeverageAuth
///         hash wrapped in Safe's domain, or (b) having the hash pre-approved in
///         signedMessages via signMessage. This module implements (b): once enabled on a
///         user's Safe, it accepts the borrower's EOA signature off-chain (verified here)
///         and atomically marks the hash as approved on the Safe via SignMessageLib.
///         The relayer then calls pullUsdcForLeverage with empty bytes for fromSignature
///         and Safe's isValidSignature returns true via the pre-approved-hash branch.
///
///         Trust model: the borrower's EOA signature is the sole credential. The module
///         requires that signer to be an owner of the Safe. Threshold > 1 Safes are not
///         supported on this module's path — they would still need to sign via Safe's
///         multi-owner flow on every leverage open.
contract PredmartLeverageModule {
    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The LendingPool whose LeverageAuth hashes this module pre-approves.
    address public immutable LENDING_POOL;

    /// @notice Safe's official SignMessageLib for the deployment chain (delegatecall target).
    address public immutable SIGN_MESSAGE_LIB;

    /// @notice EIP-712 typehash for LeverageAuth — must match the pool exactly.
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );

    /// @notice Pool's EIP-712 domain separator. Computed at construction so verification
    ///         doesn't depend on a runtime pool call. Must match pool's _hashTypedDataV4Ext.
    bytes32 public immutable POOL_DOMAIN_SEPARATOR;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct LeverageAuth {
        address borrower;
        address allowedFrom;
        uint256 tokenId;
        uint256 maxBorrow;
        uint256 nonce;
        uint256 deadline;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS / ERRORS
    //////////////////////////////////////////////////////////////*/

    event AuthPreapproved(address indexed safe, bytes32 indexed authHash, address indexed borrower);

    error WrongSafe();
    error InvalidBorrowerSignature();
    error BorrowerNotSafeOwner();
    error SignMessageFailed();

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address pool, address signMessageLib) {
        LENDING_POOL = pool;
        SIGN_MESSAGE_LIB = signMessageLib;
        POOL_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Predmart Lending Pool")),
                keccak256(bytes("0.8.0")),
                block.chainid,
                pool
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 PRE-APPROVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pre-approve a LeverageAuth hash on the user's Safe.
    ///         Verifies the borrower's EOA signed the LeverageAuth, that the borrower is
    ///         an owner of the Safe, then atomically marks the auth hash as approved on
    ///         the Safe via SignMessageLib.signMessage (delegatecall).
    /// @dev    Permissionless: anyone may call (typically the PredMart relayer). The
    ///         only credentials are the borrower's EOA signature + Safe-ownership check.
    ///         Replay-safe because each LeverageAuth has a single-use nonce enforced by
    ///         the pool.
    function preapproveAuth(ISafe safe, LeverageAuth calldata auth, bytes calldata authSignature) external {
        if (auth.allowedFrom != address(safe)) revert WrongSafe();

        bytes32 structHash = keccak256(
            abi.encode(
                LEVERAGE_AUTH_TYPEHASH,
                auth.borrower,
                auth.allowedFrom,
                auth.tokenId,
                auth.maxBorrow,
                auth.nonce,
                auth.deadline
            )
        );
        bytes32 authHash = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), POOL_DOMAIN_SEPARATOR, structHash));

        if (!SignatureChecker.isValidSignatureNow(auth.borrower, authHash, authSignature)) {
            revert InvalidBorrowerSignature();
        }
        if (!safe.isOwner(auth.borrower)) revert BorrowerNotSafeOwner();

        // Delegatecall to SignMessageLib runs in the Safe's storage context, computes
        // the Safe-domain-wrapped messageHash for `authHash`, and writes
        // signedMessages[messageHash] = 1. The pool's subsequent
        // SignatureChecker.isValidSignatureNow(safe, authHash, "") then succeeds via
        // Safe's pre-approved-hash branch.
        bytes memory signCalldata = abi.encodeWithSelector(SIGN_MESSAGE_SELECTOR, abi.encode(authHash));
        bool ok = safe.execTransactionFromModule(SIGN_MESSAGE_LIB, 0, signCalldata, OP_DELEGATECALL);
        if (!ok) revert SignMessageFailed();

        emit AuthPreapproved(address(safe), authHash, auth.borrower);
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 private constant SIGN_MESSAGE_SELECTOR = bytes4(keccak256("signMessage(bytes)"));
    uint8 private constant OP_DELEGATECALL = 1;
}

interface ISafe {
    function isOwner(address owner) external view returns (bool);
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}
