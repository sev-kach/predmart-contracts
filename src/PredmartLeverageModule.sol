// src/PredmartLeverageModule.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/// @title PredmartLeverageModule
/// @notice Safe Module that, in a single transaction, verifies a borrower's LeverageAuth
///         signature, pulls the user's equity from their Gnosis Safe to the relayer via
///         `Safe.execTransactionFromModule`, and calls the pool's `pullUsdcForLeverage`
///         to record accounting and advance the borrowed USDC.
///
/// @dev    Trust model: the borrower's EOA signature plus Safe-ownership are the only
///         credentials. The pool restricts `pullUsdcForLeverage` to the address registered
///         as `leverageModule` (this contract), so the module is the sole authorized
///         caller of that function. The pool re-derives the auth hash from `auth` so a
///         malicious module cannot redirect accounting to a forged hash.
contract PredmartLeverageModule {
    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The LendingPool whose accounting this module triggers via pullUsdcForLeverage.
    address public immutable LENDING_POOL;

    /// @notice The relayer address that receives userAmount USDC pulled from the Safe.
    ///         Must match pool.relayer(). If pool's relayer rotates, redeploy this module.
    address public immutable RELAYER;

    /// @notice The collateral token transferred from the Safe (USDC.e on Polygon today,
    ///         pUSD post-V2 migration). Must match pool's underlying ERC-4626 asset.
    address public immutable USDC;

    /// @notice EIP-712 typehash for LeverageAuth — must match the pool exactly.
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );

    /// @notice Pool's EIP-712 domain separator. Computed at construction so verification
    ///         doesn't depend on a runtime pool call. Must match pool's _hashTypedDataV4Ext.
    bytes32 public immutable POOL_DOMAIN_SEPARATOR;

    /// @notice On-chain version string for runtime introspection.
    string public constant VERSION = "1.0.0";

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

    event LeverageExecuted(
        address indexed safe,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 userAmount,
        uint256 advanceAmount
    );

    error WrongSafe();
    error InvalidBorrowerSignature();
    error BorrowerNotSafeOwner();
    error SafeUsdcPullFailed();

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address pool, address relayer, address usdc) {
        LENDING_POOL = pool;
        RELAYER = relayer;
        USDC = usdc;
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
                                 EXECUTE LEVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Atomically: verify the borrower's LeverageAuth signature, pull
    ///         userAmount USDC from the Safe to the relayer, and trigger the pool's
    ///         advance + accounting via pullUsdcForLeverage.
    /// @dev    Permissionless caller. The borrower's EOA signature plus Safe-ownership
    ///         check are the sole credentials. Replay-safe via the pool's nonce + the
    ///         single-use leverageBorrowUsed budget against auth.maxBorrow.
    /// @param  safe           Gnosis Safe v1.x with this module enabled. Must equal auth.allowedFrom.
    /// @param  auth           The user's leverage authorization (typed data, signed off-chain).
    /// @param  authSignature  Borrower's EIP-712 signature over `auth` against the pool's domain.
    /// @param  userAmount     USDC pulled from Safe → relayer (the user's equity contribution).
    /// @param  advanceAmount  USDC the pool advances to relayer for the CLOB buy (formalized as borrow in leverageDeposit).
    function executeLeverage(
        ISafe safe,
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        uint256 userAmount,
        uint256 advanceAmount
    ) external {
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

        // Pull the user's equity from the Safe to the relayer using module privilege.
        // execTransactionFromModule with operation=CALL → Safe sends the USDC.transfer
        // call as itself, transferring its own balance.
        if (userAmount > 0) {
            bytes memory transferCall = abi.encodeWithSelector(IERC20.transfer.selector, RELAYER, userAmount);
            bool ok = safe.execTransactionFromModule(USDC, 0, transferCall, OP_CALL);
            if (!ok) revert SafeUsdcPullFailed();
        }

        // Pool does maxBorrow + nonce + initialEquity accounting and the pool→relayer advance.
        // pullUsdcForLeverage is gated by msg.sender == leverageModule (this contract).
        IPredmartPool(LENDING_POOL).pullUsdcForLeverage(auth, userAmount, advanceAmount);

        emit LeverageExecuted(address(safe), auth.borrower, auth.tokenId, userAmount, advanceAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant OP_CALL = 0;
}

interface ISafe {
    function isOwner(address owner) external view returns (bool);
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPredmartPool {
    /// @notice Pool's onlyModule entry — module-verified accounting + advance.
    ///         Called via the pool's fallback → extension delegatecall.
    function pullUsdcForLeverage(
        PredmartLeverageModule.LeverageAuth calldata auth,
        uint256 userAmount,
        uint256 advanceAmount
    ) external;
}
