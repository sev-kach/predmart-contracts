// src/PredmartLeverageModule.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/// @title PredmartLeverageModule
/// @notice Safe Module that, in a single transaction, verifies a borrower's LeverageAuth
///         signature, pulls the user's equity (in pUSD) from their Gnosis Safe to the
///         relayer via `Safe.execTransactionFromModule`, and calls the pool's
///         `pullUsdcForLeverage` to record accounting and advance the borrowed USDC.e.
///
/// @dev    V2-native: the user's Safe holds pUSD by default (Polymarket's V2 trading
///         currency). The module pulls pUSD; if the Safe lacks enough pUSD but has
///         USDC.e, the module wraps all of the Safe's USDC.e to pUSD via CollateralOnramp
///         first, then pulls pUSD. Wrap-all simplifies the code (no shortfall math) and
///         leaves the Safe in a uniformly-pUSD state, which matches the user's intent.
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

    /// @notice The relayer address that receives userAmount pUSD pulled from the Safe.
    ///         Must match pool.relayer(). If pool's relayer rotates, redeploy this module.
    address public immutable RELAYER;

    /// @notice Pool's underlying asset — USDC.e (bridged Circle USDC on Polygon).
    ///         Used as the wrap source when the Safe lacks pUSD.
    address public immutable USDC_E;

    /// @notice Polymarket V2 trading currency. Pulled from Safe to relayer.
    address public immutable PUSD;

    /// @notice Polymarket's CollateralOnramp — wraps USDC.e into pUSD 1:1.
    address public immutable COLLATERAL_ONRAMP;

    /// @notice EIP-712 typehash for LeverageAuth — must match the pool exactly.
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,address recipient,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );

    /// @notice Pool's EIP-712 domain separator. Computed at construction so verification
    ///         doesn't depend on a runtime pool call. Must match pool's _hashTypedDataV4Ext.
    bytes32 public immutable POOL_DOMAIN_SEPARATOR;

    /// @notice On-chain version string for runtime introspection.
    string public constant VERSION = "2.0.0";

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct LeverageAuth {
        address borrower;
        address allowedFrom;
        address recipient;  // V2-native — destination for redemption surplus (user's Safe).
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
    error SafePullFailed();
    error SafeWrapFailed();
    error InsufficientSafeFunds();
    error InvalidRecipient();

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address pool, address relayer, address usdcE, address pusd, address collateralOnramp) {
        LENDING_POOL = pool;
        RELAYER = relayer;
        USDC_E = usdcE;
        PUSD = pusd;
        COLLATERAL_ONRAMP = collateralOnramp;
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
    ///         userAmount pUSD from the Safe to the relayer (wrapping Safe's USDC.e
    ///         first if needed), and trigger the pool's advance + accounting via
    ///         pullUsdcForLeverage.
    /// @dev    Permissionless caller. The borrower's EOA signature plus Safe-ownership
    ///         check are the sole credentials. Replay-safe via the pool's nonce + the
    ///         single-use leverageBorrowUsed budget against auth.maxBorrow.
    /// @dev    Wrap-all behavior: if Safe.pUSD < userAmount, wraps the entire USDC.e
    ///         balance of the Safe to pUSD (no shortfall math). Caller must ensure
    ///         Safe.pUSD + Safe.USDC.e >= userAmount or the second pull reverts.
    /// @param  safe           Gnosis Safe v1.x with this module enabled. Must equal auth.allowedFrom.
    /// @param  auth           The user's leverage authorization (typed data, signed off-chain).
    /// @param  authSignature  Borrower's EIP-712 signature over `auth` against the pool's domain.
    /// @param  userAmount     pUSD pulled from Safe → relayer (the user's equity contribution).
    /// @param  advanceAmount  USDC.e the pool advances to relayer for the CLOB buy (formalized as borrow in leverageDeposit).
    function executeLeverage(
        ISafe safe,
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        uint256 userAmount,
        uint256 advanceAmount
    ) external {
        if (auth.allowedFrom != address(safe)) revert WrongSafe();
        if (auth.recipient == address(0)) revert InvalidRecipient();

        bytes32 structHash = keccak256(
            abi.encode(
                LEVERAGE_AUTH_TYPEHASH,
                auth.borrower,
                auth.allowedFrom,
                auth.recipient,
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

        if (userAmount > 0) {
            uint256 pusdBalance = IERC20(PUSD).balanceOf(address(safe));
            // If Safe is short pUSD, wrap-all of its USDC.e into pUSD first. The Safe's
            // USDC.e → CollateralOnramp approval is granted at onboarding (Step 3); the
            // wrap call below uses that approval as msg.sender = Safe.
            if (pusdBalance < userAmount) {
                uint256 usdcEBalance = IERC20(USDC_E).balanceOf(address(safe));
                if (usdcEBalance + pusdBalance < userAmount) revert InsufficientSafeFunds();
                if (usdcEBalance > 0) {
                    bytes memory wrapCall = abi.encodeWithSelector(
                        ICollateralOnramp.wrap.selector,
                        USDC_E,
                        address(safe),
                        usdcEBalance
                    );
                    bool wrapOk = safe.execTransactionFromModule(COLLATERAL_ONRAMP, 0, wrapCall, OP_CALL);
                    if (!wrapOk) revert SafeWrapFailed();
                }
            }

            // Pull pUSD from Safe to relayer.
            bytes memory transferCall = abi.encodeWithSelector(IERC20.transfer.selector, RELAYER, userAmount);
            bool transferOk = safe.execTransactionFromModule(PUSD, 0, transferCall, OP_CALL);
            if (!transferOk) revert SafePullFailed();
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
    function balanceOf(address account) external view returns (uint256);
}

interface ICollateralOnramp {
    /// @notice Wraps `_amount` of `_asset` (USDC.e) from `msg.sender` into pUSD, minted to `_to`.
    function wrap(address _asset, address _to, uint256 _amount) external;
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
