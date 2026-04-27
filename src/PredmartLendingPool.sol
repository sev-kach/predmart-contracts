// SPDX-License-Identifier: MIT
// contracts/src/PredmartLendingPool.sol
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // OZ 5.5+ uses ERC-7201 namespaced storage — proxy-safe, no ReentrancyGuardUpgradeable needed
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { ICTF } from "./interfaces/ICTF.sol";
import {
    Position, MarketResolution, Redemption, PendingClose, PendingLiquidation,
    NotAdmin, InvalidAddress, NoPosition, TimelockNotReady, NoPendingChange, NotRelayer, NoPendingLiquidation, NotLiquidator, TokenFrozen,
    BadDebtAbsorbed, InterestAccrued, PositionCloseInitiated, OperationFeeCollected, LiquidationSettled, ProfitFeeCollected, CollateralDeposited
} from "./PredmartTypes.sol";

/// @title PredmartLendingPool
/// @notice Lending pool for borrowing USDC against Polymarket prediction market shares (ERC-1155)
/// @dev UUPS Upgradeable — shares-based debt with global interest accrual
/// @author Predmart
contract PredmartLendingPool is
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard,
    ERC1155Holder
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    string public constant VERSION = "2.0.0";

    uint256 public constant MAX_RELAY_PRICE_AGE = 60 seconds;
    uint256 public constant NUM_ANCHORS = 7;
    uint256 public constant MIN_BORROW = 1e6; // $1 USDC minimum debt
    uint256 public constant CLOSE_TIMEOUT = 48 hours; // Max duration for pending flash close settlement

    // EIP-712 typehashes for meta-transaction intents
    bytes32 public constant BORROW_INTENT_TYPEHASH = keccak256(
        "BorrowIntent(address borrower,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH = keccak256(
        "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant CLOSE_AUTH_TYPEHASH = keccak256(
        "CloseAuth(address borrower,address allowedTo,uint256 tokenId,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant DEPOSIT_COLLATERAL_FROM_TYPEHASH = keccak256(
        "DepositCollateralFromAuth(address from,address creditTo,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ProtocolPaused();
    error MarketResolved();
    error PositionHealthy();
    error ExceedsLTV();
    error InsufficientLiquidity();
    error BorrowTooSmall();
    error ExceedsTokenCap();
    error DepthCapExceeded();
    error IntentExpired();
    error InvalidIntentSignature();
    error InvalidNonce();
    error ExceedsBorrowBudget();
    error AuthAlreadyUsed();
    error PositionHasPendingClose();
    error NoPendingClose();
    error CloseNotExpired();
    error PositionUnhealthy();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralWithdrawn(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event Borrowed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    // Repaid event moved to PredmartTypes (now emitted from extension's repay function)
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 collateralSeized,
        uint256 debtRepaid
    );
    event ReservesWithdrawn(address indexed to, uint256 amount);
    event ExtensionUpdated(address indexed newExtension);
    event ExtensionChangeProposed(address indexed newExtension, uint256 execAfter);
    event LeverageModuleUpdated(address indexed newModule);
    // LeverageModuleChangeProposed / LeverageModuleChangeCancelled declared in extension.

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-712 typed data for borrow intent (signed by borrower off-chain)
    struct BorrowIntent {
        address borrower;
        uint256 tokenId;
        uint256 amount; // USDC (6 decimals)
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice EIP-712 typed data for withdraw intent (signed by borrower off-chain)
    struct WithdrawIntent {
        address borrower;
        address to; // Destination for collateral (e.g. Polymarket Safe proxy)
        uint256 tokenId;
        uint256 amount; // Shares to withdraw
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice EIP-712 authorization for a leverage operation (signed once, reusable within budget)
    struct LeverageAuth {
        address borrower;
        address allowedFrom; // Permitted source for CTF shares (user's Safe or relayer, always allowed via msg.sender)
        uint256 tokenId;
        uint256 maxBorrow; // Max cumulative USDC the relayer can borrow under this auth (6 decimals)
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice EIP-712 authorization for pool-funded flash close (signed once, closes entire position)
    struct CloseAuth {
        address borrower;
        address allowedTo; // Surplus USDC destination after settlement (user's Safe)
        uint256 tokenId;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Non-signature parameters bundled into a struct to avoid stack-too-deep in leverageDeposit.
    struct LeverageDepositData {
        address from;         // Address holding CTF shares (user's Safe or relayer)
        address borrowTo;     // Destination for borrowed USDC (user's Safe or relayer)
        uint256 depositAmount;
        uint256 borrowAmount;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE — SLOT 0+
    //////////////////////////////////////////////////////////////*/

    // SLOT 0 — preserved from v0.1.0 for upgrade compatibility
    address public admin;

    // SLOT 1+ — v0.2.0+
    address public oracle;
    address public ctf;
    uint256 public totalBorrowAssets; // Total outstanding debt across all positions (USDC 6 decimal)
    uint256 public totalBorrowShares; // Total borrow shares across all positions
    uint256 public lastAccrualTimestamp; // Last time global interest was accrued
    uint256 public totalReserves; // Protocol revenue from interest (USDC 6 decimal)

    // Risk model anchors (7 points each) — admin-tunable
    uint256[NUM_ANCHORS] public priceAnchors;
    uint256[NUM_ANCHORS] public ltvAnchors;

    // Per-borrower, per-token positions
    mapping(address => mapping(uint256 => Position)) public positions;

    // Market resolution tracking
    mapping(uint256 => MarketResolution) public resolvedMarkets;

    // Per-token freeze — blocks new deposits and borrows for a specific token
    mapping(uint256 => bool) public frozenTokens;

    // Emergency pause — blocks new borrows and collateral deposits
    bool public paused;

    // CTF redemption tracking — for settling won-market positions
    mapping(uint256 => Redemption) public redeemedTokens; // tokenId => redemption details
    uint256 public unsettledRedemptions; // USDC received from CTF redemptions but not yet settled against positions

    // Timelock — ratchet (can only increase, never decrease)
    // PRODUCTION: 6h timelock active on-chain (21600s). Persists across UUPS upgrades.
    uint256 public timelockDelay;

    // Pending timelocked changes
    address public pendingOracle;
    uint256 public pendingOracleExecAfter;

    uint256[NUM_ANCHORS] public pendingPriceAnchors;
    uint256[NUM_ANCHORS] public pendingLtvAnchors;
    uint256 public pendingAnchorsExecAfter;

    address public pendingUpgrade;
    uint256 public pendingUpgradeExecAfter;

    // v0.6.0 — Per-token borrow cap (prevents single-market concentration risk)
    mapping(uint256 => uint256) public totalBorrowedPerToken; // tokenId => total USDC borrowed against it
    uint256 public poolCapBps; // Max borrow per token = totalAssets() * poolCapBps / 10000 (default 500 = 5%)

    // v0.8.0 — Meta-transaction relayer pattern (eliminates oracle price staleness attack)
    address public relayer; // Trusted relayer address — only this address can call borrowViaRelay/withdrawViaRelay/liquidate
    mapping(address => uint256) public borrowNonces; // Per-user nonce for EIP-712 intent replay protection

    // v0.9.1 — Timelocked relayer rotation + separate withdraw nonces
    address public pendingRelayer;
    uint256 public pendingRelayerExecAfter;
    mapping(address => uint256) public withdrawNonces;
    address public extension; // v0.9.1 — extension contract for admin functions (delegatecall target)
    address public pendingAdmin; // v0.9.1 — timelocked admin transfer
    uint256 public pendingAdminExecAfter;

    // v1.0.0 — Leverage authorization
    mapping(address => uint256) public leverageNonces; // Separate nonce for leverage (doesn't interfere with borrow/withdraw nonces)
    mapping(bytes32 => uint256) public leverageBorrowUsed; // authHash => cumulative USDC borrowed under this auth

    // v1.1.0 — DEPRECATED (kept for proxy storage layout — no public getter)
    mapping(address => uint256) internal deleverageNonces;
    mapping(bytes32 => uint256) internal deleverageWithdrawUsed;

    // v1.2.0 — Pool-funded flash close (v1.6.0: changed to per-position nonces for TP/SL support)
    mapping(address => mapping(uint256 => uint256)) public closeNonces; // borrower => tokenId => nonce
    uint256 public totalPendingCloses; // Sum of all pending close debt amounts (USDC 6 decimal)
    mapping(address => mapping(uint256 => PendingClose)) public pendingCloses; // borrower => tokenId => pending

    // v1.3.0 — Flat fee for relayed operations (spam protection / relayer gas sustainability)
    uint256 public operationFee; // USDC (6 decimals). E.g. 30000 = $0.03
    uint256 public operationFeePool; // Accumulated USDC fees dedicated to relayer gas top-up
    mapping(uint256 => uint256) public feeSharesAccumulated; // tokenId => CTF shares collected as withdrawal fees

    // v1.5.0 — Leverage advance: pool advances borrow USDC to relayer before collateral is deposited
    mapping(bytes32 => uint256) public pendingAdvances; // authHash => USDC advanced to relayer
    uint256 public totalPendingAdvances; // Global sum for liquidity monitoring
    uint256 private _advanceOffset; // Transient: used to pass advance offset to _executeBorrow

    // v1.7.0 — NegRisk support: adapter for redeeming neg_risk CTF positions
    address public negRiskAdapter;

    // v2.0.0 — Pending liquidations (seize-first model)
    mapping(address => mapping(uint256 => PendingLiquidation)) public pendingLiquidations;
    uint256 public totalPendingLiquidations;

    // v2.0.0 — Protocol fee accumulator (3% of profit fees)
    uint256 public protocolFeePool;

    // v2.0.0 — Separate liquidator wallet (can call liquidate + settleLiquidation)
    address public liquidator;

    // v2.1.0 — Advance timestamps for permissionless expiry
    mapping(bytes32 => uint256) public pendingAdvanceTimestamps;

    // v2.2.0 — Timelocked liquidator rotation
    address public pendingLiquidator;
    uint256 public pendingLiquidatorExecAfter;

    // v2.3.0 — EIP-1271 signature auth for depositCollateralFrom
    mapping(address => uint256) public depositCollateralFromNonces;

    // v2.3.1 — Timelocked extension rotation. Lives in main pool so extension swap works even if current extension is broken.
    address public pendingExtension;
    uint256 public pendingExtensionExecAfter;

    // v2.4.0 — Deposit-only call tracking per LeverageAuth (replay protection for leverageDeposit(borrowAmount=0)).
    // Without this, the deposit branch of leverageDeposit runs unconditionally for any presented signature,
    // letting a buggy or compromised relayer pull additional Safe shares against the user's standing CTF
    // approval as long as the auth deadline has not expired.
    mapping(bytes32 => bool) public leverageDepositOnlyConsumed;

    // Leverage module + timelocked rotation. Set via initializeV17; rotated via
    // proposeLeverageModule + executeLeverageModule. The module is the sole authorized
    // caller of PredmartPoolExtension.pullUsdcForLeverage.
    // Declared `internal` here to avoid duplicating auto-getters that already exist on
    // the extension (saves ~300 bytes of pool bytecode); read externally via extension.
    address internal _leverageModule;
    address internal _pendingLeverageModule;
    uint256 internal _pendingLeverageModuleExecAfter;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }


    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize v0.1.0 — sets admin. Used for fresh deployments; on mainnet this has already run.
    function initialize(address _admin) public initializer {
        admin = _admin;
    }

    /// @notice Initialize v0.2.0+ — ERC20/ERC4626 init + risk model anchors. Already executed on mainnet.
    function initializeV2(address _oracle, address _usdc, address _ctf) public reinitializer(2) {
        __ERC20_init("Predmart USDC", "pUSDC");
        __ERC4626_init(IERC20(_usdc));
        oracle = _oracle;
        ctf = _ctf;
        priceAnchors = [uint256(0), 0.10e18, 0.20e18, 0.40e18, 0.60e18, 0.80e18, 1.00e18];
        ltvAnchors = [uint256(0.02e18), 0.08e18, 0.30e18, 0.45e18, 0.60e18, 0.70e18, 0.75e18];
    }

    /// @notice Initialize v0.6.0 — per-token borrow cap. Already executed on mainnet.
    function initializeV3() public reinitializer(3) {
        poolCapBps = 500;
    }

    /// @notice Initialize v0.8.0 — EIP-712 domain + relayer. Already executed on mainnet.
    function initializeV4(address _relayer) public reinitializer(4) {
        __EIP712_init("Predmart Lending Pool", "0.8.0");
        relayer = _relayer;
    }

    // initializeV5-V14 removed — already executed on mainnet, reinitializer prevents reuse.
    // V1-V4 retained because test/deploy scripts use them for fresh-proxy setup.
    // Future upgrades MUST add a fresh `initializeVN` with `reinitializer(N)` for any new state setup.

    /// @notice Atomic extension rotation during UUPS upgrade.
    /// @dev The reinitializer is callable only once via `upgradeToAndCall`, which is itself
    ///      gated by the proposeAddress timelock — so this safely bypasses the setExtension
    ///      timelock for a governance-approved upgrade.
    function initializeV15(address _extension) public reinitializer(15) {
        if (_extension == address(0)) revert InvalidAddress();
        extension = _extension;
        emit ExtensionUpdated(_extension);
    }

    /// @notice Atomic extension rotation for v16 upgrade.
    /// @dev Code-only fix (initialEquity correctly reduced on borrow/withdraw to prevent
    ///      profit-fee underpayment on mixed leverage+borrow positions). No new storage.
    function initializeV16(address _extension) public reinitializer(16) {
        if (_extension == address(0)) revert InvalidAddress();
        extension = _extension;
        emit ExtensionUpdated(_extension);
    }

    /// @notice Atomic extension + leverage-module wiring during a UUPS upgrade.
    /// @dev    Wires the PredmartLeverageModule into pool storage as the sole caller of
    ///         pullUsdcForLeverage. Bypasses both setExtension and setLeverageModule
    ///         timelocks because the reinitializer is itself reachable only via
    ///         upgradeToAndCall, which is gated by the proposeAddress(2) timelock.
    /// @param  _extension          Extension implementation to wire (reuse current if unchanged).
    /// @param  _leverageModuleAddr Module address.
    function initializeV17(address _extension, address _leverageModuleAddr) public reinitializer(17) {
        if (_extension == address(0)) revert InvalidAddress();
        if (_leverageModuleAddr == address(0)) revert InvalidAddress();
        extension = _extension;
        _leverageModule = _leverageModuleAddr;
        emit ExtensionUpdated(_extension);
        emit LeverageModuleUpdated(_leverageModuleAddr);
    }

    /*//////////////////////////////////////////////////////////////
                        GLOBAL INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    // accrueInterest() (public wrapper) moved to PredmartPoolExtension (size)

    /// @dev Accrue interest on the entire borrow pool. Called before every state-changing operation.
    /// All borrowers' debt grows proportionally through the totalBorrowAssets/totalBorrowShares ratio.
    /// SYNC: PredmartPoolExtension._accrueInterestInline() must match this logic exactly.
    function _accrueInterest() internal {
        if (totalBorrowAssets == 0) {
            lastAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        (uint256 interest, uint256 reserveShare) = PredmartPoolLib.calcPendingInterest(
            totalBorrowAssets, elapsed, getUtilization()
        );

        if (interest > 0) {
            totalBorrowAssets += interest;
            totalReserves += reserveShare;
            emit InterestAccrued(interest, reserveShare);
        }

        lastAccrualTimestamp = block.timestamp;
    }

    /// @dev Compute pending (unaccrued) interest since last accrual — view-only, no state writes.
    ///      Used by view functions to return real-time values without requiring a transaction.
    function _pendingInterest() internal view returns (uint256 interest, uint256 reserveShare) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        return PredmartPoolLib.calcPendingInterest(totalBorrowAssets, elapsed, getUtilization());
    }

    /*//////////////////////////////////////////////////////////////
                         BORROW SHARES MATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Convert borrow assets (USDC) to borrow shares (used by state-changing functions after _accrueInterest)
    function _toBorrowShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalBorrowShares + 1e6, totalBorrowAssets + 1, rounding);
    }

    /// @dev Convert borrow shares to borrow assets (used by state-changing functions after _accrueInterest)
    function _toBorrowAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalBorrowAssets + 1, totalBorrowShares + 1e6, rounding);
    }

    /// @dev Convert borrow shares to borrow assets including pending interest — for view functions only.
    function _toBorrowAssetsView(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        (uint256 interest,) = _pendingInterest();
        return shares.mulDiv((totalBorrowAssets + interest) + 1, totalBorrowShares + 1e6, rounding);
    }

    /// @dev Reduce global borrow tracking (safe subtraction — floors at 0 for rounding edge cases)
    function _reduceBorrowTracking(uint256 tokenId, uint256 assets, uint256 shares, uint256 principalReduction) internal {
        totalBorrowAssets = totalBorrowAssets > assets ? totalBorrowAssets - assets : 0;
        totalBorrowShares = totalBorrowShares > shares ? totalBorrowShares - shares : 0;
        if (totalBorrowAssets == 0 && totalBorrowShares > 0) totalBorrowShares = 0;
        if (totalBorrowShares == 0 && totalBorrowAssets > 0) totalBorrowAssets = 0;
        totalBorrowedPerToken[tokenId] = totalBorrowedPerToken[tokenId] > principalReduction
            ? totalBorrowedPerToken[tokenId] - principalReduction : 0;
    }

    /*//////////////////////////////////////////////////////////////
                          ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Raw total assets without pending interest — used by getUtilization/getBorrowRate
    ///      to avoid circular dependency (_pendingInterest → getBorrowRate → getUtilization → totalAssets).
    function _totalAssetsStale() internal view returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalBorrowAssets + totalPendingCloses + totalPendingAdvances + totalPendingLiquidations;
        total = total > totalReserves ? total - totalReserves : 0;
        total = total > unsettledRedemptions ? total - unsettledRedemptions : 0;
        total = total > operationFeePool ? total - operationFeePool : 0;
        total = total > protocolFeePool ? total - protocolFeePool : 0;
        return total;
    }

    /// @dev Available USDC in the contract excluding reserves, unsettled redemptions, and earmarked fees.
    ///      `totalPendingAdvances` is NOT subtracted here: advances have already left the pool's
    ///      USDC balance when `pullUsdcForLeverage` transferred them to the relayer, so subtracting
    ///      again would double-count. The pending advance is tracked separately for settlement/expiry
    ///      bookkeeping, not as a claim on current cash.
    function _availableCash() internal view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        cash = cash > totalReserves ? cash - totalReserves : 0;
        cash = cash > unsettledRedemptions ? cash - unsettledRedemptions : 0;
        cash = cash > operationFeePool ? cash - operationFeePool : 0;
        cash = cash > protocolFeePool ? cash - protocolFeePool : 0;
        return cash;
    }

    /// @notice Total assets available to lenders, including pending (unaccrued) interest.
    ///         Used by ERC-4626 for share pricing — always returns real-time value.
    function totalAssets() public view override returns (uint256) {
        (uint256 interest, uint256 reserveShare) = _pendingInterest();
        return _totalAssetsStale() + interest - reserveShare;
    }

    /// @dev Virtual shares offset to prevent first-depositor inflation attack (ERC-4626).
    /// With offset=6, the vault behaves as if 1e6 virtual shares always exist,
    /// making share price manipulation economically impossible.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Limit withdrawals to available liquidity (USDC in contract minus reserves and unsettled redemptions)
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 available = _availableCash();
        return ownerAssets < available ? ownerAssets : available;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 maxAssets = _convertToShares(_availableCash(), Math.Rounding.Floor);
        return ownerShares < maxAssets ? ownerShares : maxAssets;
    }

    /// @dev Add reentrancy protection + global interest accrual to deposit.
    ///      Intentionally lacks whenNotPaused: during emergencies, allowing deposits provides
    ///      liquidity for repayments and liquidations. Blocking deposits during pause would
    ///      worsen a liquidity crisis.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.deposit(assets, receiver);
    }

    /// @dev Add reentrancy protection + global interest accrual to mint.
    ///      Intentionally lacks whenNotPaused (same rationale as deposit — see above).
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.mint(shares, receiver);
    }

    /// @dev Add reentrancy protection + global interest accrual to withdraw
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev Add reentrancy protection + global interest accrual to redeem
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                        BORROWER — COLLATERAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit ERC-1155 prediction market shares as collateral (from msg.sender)
    /// @param tokenId Polymarket CTF token ID
    /// @param amount Number of shares to deposit
    /// @param priceData Signed oracle price — used to track initialEquity for accurate profit fee
    // depositCollateral() (direct EOA) moved to PredmartPoolExtension (size).
    // Users with Polymarket Safes should use depositCollateralFrom (meta-tx).

    /// @notice Deposit collateral from a third-party address (e.g. Polymarket Safe proxy) authorized by EIP-712 signature.
    /// @dev The `from` address must have approved this contract via setApprovalForAll.
    ///      Authorization is verified via `SignatureChecker.isValidSignatureNow(from, digest, signature)`,
    ///      which supports both ECDSA (EOAs) and EIP-1271 (contract accounts like Gnosis Safe).
    ///      For a multi-sig Safe, the signature must be produced by the Safe's threshold of owners —
    ///      a single rogue owner cannot authorize the action.
    ///
    ///      SPAM PROTECTION: When submitted via the relayer (`msg.sender == relayer`), `operationFee`
    ///      worth of shares is deducted from the deposit and accumulated in `feeSharesAccumulated`.
    ///      Same pattern as `withdrawViaRelay`. For direct submissions (user pays own gas), no fee.
    /// @param from Address holding the CTF shares (e.g. user's Gnosis Safe)
    /// @param creditTo Address credited with the collateral position (explicitly authorized in the signature)
    /// @param tokenId Polymarket CTF token ID
    /// @param amount Number of shares to deposit
    /// @param nonce Per-`from` replay nonce (must equal depositCollateralFromNonces[from])
    /// @param deadline EIP-712 expiration timestamp
    /// @param signature `from`'s EIP-712 signature over DepositCollateralFromAuth
    /// @param priceData Signed oracle price — used for fee calculation and initialEquity tracking
    function depositCollateralFrom(
        address from,
        address creditTo,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert IntentExpired();
        if (nonce != depositCollateralFromNonces[from]) revert InvalidNonce();

        bytes32 structHash = keccak256(abi.encode(
            DEPOSIT_COLLATERAL_FROM_TYPEHASH,
            from, creditTo, tokenId, amount, nonce, deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);

        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) {
            revert InvalidIntentSignature();
        }

        depositCollateralFromNonces[from]++;

        // Verify oracle price (needed for both fee calc and equity tracking)
        if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        // Spam protection: compute operationFee in shares for relayed calls.
        // If fee >= amount, entire deposit taken as fee (no position credit).
        uint256 feeInShares;
        if (operationFee > 0 && msg.sender == relayer) {
            feeInShares = operationFee.mulDiv(1e18, price, Math.Rounding.Ceil);
            if (feeInShares > amount) feeInShares = amount;
            feeSharesAccumulated[tokenId] += feeInShares;
            emit OperationFeeCollected(from, operationFee);
        }

        // Pull full `amount` from `from`, credit only (amount - feeInShares) to position.
        // `_depositCollateral` emits `CollateralDeposited` with the credited amount,
        // so the event value exactly matches the position's state change.
        uint256 credited = amount - feeInShares;
        _depositCollateral(creditTo, from, tokenId, amount, credited);

        // Track equity based on credited amount (post-fee)
        positions[creditTo][tokenId].initialEquity += credited * price / 1e18;
    }

    /// @dev Internal deposit: transfers `pullAmount` CTF shares from `from` and credits `creditAmount`
    ///      to `creditTo`'s position. When `pullAmount > creditAmount`, the difference is the fee
    ///      (caller is responsible for adding it to `feeSharesAccumulated[tokenId]`).
    ///      `creditTo` == `from` for direct deposits; `creditTo` != `from` for relay-based deposits
    ///      (e.g. leverage: relayer deposits from Safe, position credited to the EOA borrower).
    ///      The `CollateralDeposited` event emits `creditAmount` — the actual position state change.
    function _depositCollateral(
        address creditTo,
        address from,
        uint256 tokenId,
        uint256 pullAmount,
        uint256 creditAmount
    ) internal {
        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();
        if (pendingCloses[creditTo][tokenId].deadline != 0) revert PositionHasPendingClose();

        ICTF(ctf).safeTransferFrom(from, address(this), tokenId, pullAmount, "");

        positions[creditTo][tokenId].collateralAmount += creditAmount;

        emit CollateralDeposited(creditTo, tokenId, creditAmount);
    }

    function _verifyPriceFor(uint256 expectedTokenId, PredmartOracle.PriceData calldata priceData) internal view returns (uint256) {
        if (priceData.tokenId != expectedTokenId) revert PredmartOracle.TokenIdMismatch();
        return PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
    }

    /// @dev The borrower signs an EIP-712 WithdrawIntent off-chain specifying the destination address.
    /// @param intent The borrower's signed intent (to, tokenId, amount, nonce, deadline)
    /// @param intentSignature The borrower's EIP-712 signature of the intent
    /// @param priceData Signed oracle price data (only needed if position has debt)
    function withdrawViaRelay(
        WithdrawIntent calldata intent,
        bytes calldata intentSignature,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant {
        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.nonce != withdrawNonces[intent.borrower]) revert InvalidNonce();

        // Verify borrower's EIP-712 signature via SignatureChecker so contract accounts
        // (Gnosis Safes) can withdraw via EIP-1271.
        bytes32 structHash = keccak256(abi.encode(
            WITHDRAW_INTENT_TYPEHASH, intent.borrower, intent.to, intent.tokenId,
            intent.amount, intent.nonce, intent.deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, digest, intentSignature)) {
            revert InvalidIntentSignature();
        }

        // Consume nonce
        withdrawNonces[intent.borrower]++;

        _withdrawCollateral(intent.borrower, intent.to, intent.tokenId, intent.amount, priceData);
    }

    function _withdrawCollateral(
        address borrower, address to, uint256 tokenId, uint256 amount,
        PredmartOracle.PriceData calldata priceData
    ) internal {
        _accrueInterest();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        uint256 newCollateral = pos.collateralAmount - amount;

        // Verify price when: (a) debt (health check), (b) relay fee active, or (c) initialEquity > 0.
        // Case (c) is required so initialEquity can be correctly reduced by withdrawn value;
        // without it, value extraction via withdraw would silently understate profit-fee basis.
        uint256 price;
        if (pos.borrowShares > 0 || (operationFee > 0 && msg.sender == relayer) || pos.initialEquity > 0) {
            price = _verifyPriceFor(tokenId, priceData);
        }
        if (pos.borrowShares > 0) {
            uint256 debt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            if (_getHealthFactor(newCollateral, debt, price) < 1e18) revert ExceedsLTV();
        }

        pos.collateralAmount = newCollateral;

        // Reduce initialEquity by USDC value of withdrawn collateral.
        if (pos.initialEquity > 0 && price > 0) {
            uint256 valueWithdrawn = amount.mulDiv(price, 1e18);
            pos.initialEquity = pos.initialEquity > valueWithdrawn ? pos.initialEquity - valueWithdrawn : 0;
        }

        // Collect fee in shares for relayed withdrawals.
        // If fee exceeds withdrawal, take entire withdrawal as fee (spam protection —
        // withdrawing shares worth less than $0.03 is only useful for gas drain attacks).
        uint256 feeInShares;
        if (operationFee > 0 && msg.sender == relayer) {
            feeInShares = operationFee.mulDiv(1e18, price, Math.Rounding.Ceil);
            if (feeInShares > amount) feeInShares = amount;
            feeSharesAccumulated[tokenId] += feeInShares;
            emit OperationFeeCollected(borrower, operationFee);
        }

        ICTF(ctf).safeTransferFrom(address(this), to, tokenId, amount - feeInShares, "");

        emit CollateralWithdrawn(borrower, tokenId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          BORROWER — BORROW (via relayer)
    //////////////////////////////////////////////////////////////*/

    /// @notice Borrow USDC via meta-transaction relay. Only callable by the relayer.
    /// @dev The borrower signs an EIP-712 BorrowIntent off-chain. The relayer (backend) attaches
    ///      a fresh oracle price and submits both in a single transaction. This eliminates the
    ///      oracle price staleness attack — the price is never exposed to the user.
    /// @param intent The borrower's signed intent (tokenId, amount, nonce, deadline)
    /// @param intentSignature The borrower's EIP-712 signature of the intent
    /// @param priceData Signed oracle price data (signed fresh by backend at relay time)
    function borrowViaRelay(
        BorrowIntent calldata intent,
        bytes calldata intentSignature,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.nonce != borrowNonces[intent.borrower]) revert InvalidNonce();

        // Verify borrower's EIP-712 signature via SignatureChecker so contract accounts
        // (Gnosis Safes) can borrow via EIP-1271.
        bytes32 structHash = keccak256(abi.encode(
            BORROW_INTENT_TYPEHASH, intent.borrower, intent.tokenId, intent.amount, intent.nonce, intent.deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, digest, intentSignature)) {
            revert InvalidIntentSignature();
        }

        // Consume nonce
        borrowNonces[intent.borrower]++;

        if (priceData.tokenId != intent.tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterest();
        _executeBorrow(intent.borrower, intent.tokenId, intent.amount, price, priceData.maxBorrow, intent.borrower, true);
    }

    /// @dev Verifies `allowedFrom` consents via EIP-1271/ECDSA signature over the auth hash.
    ///      No-op when `allowedFrom == borrower` (self-authorization, signature redundant).
    ///      Extracted to avoid stack-too-deep in leverageDeposit.
    function _verifyAllowedFromSig(
        address allowedFrom,
        address borrower,
        bytes32 authHash,
        bytes calldata fromSignature
    ) internal view {
        if (allowedFrom == borrower) return;
        if (!SignatureChecker.isValidSignatureNow(allowedFrom, authHash, fromSignature)) {
            revert InvalidIntentSignature();
        }
    }

    /// @notice Deposit collateral + formalize borrow for a leverage operation.
    /// @dev Only callable by the relayer. User must sign a LeverageAuth EIP-712 message authorizing
    ///      a maximum borrow budget. The contract verifies the signature and tracks cumulative borrowing
    ///      against the budget. The auth is consumed (nonce incremented) on first use and expires at deadline.
    ///      Typical flow: pullUsdcForLeverage() advances pool USDC to relayer → relayer buys shares on
    ///      CLOB → leverageDeposit() deposits all shares and formalizes the advance as real debt.
    ///
    ///      NONCE DESIGN: Nonce is consumed on first borrow, NOT on deposit-only calls.
    ///      Deposit-only calls (borrowAmount=0) are used to add pre-existing Safe shares as collateral
    ///      before the main deposit+borrow call. Replay safety is provided by the `fromSignature`
    ///      requirement below: deposits from `allowedFrom` require that address's explicit consent,
    ///      so an attacker cannot replay a deposit-only call against a victim's Safe.
    ///
    ///      When pulling shares from `allowedFrom` (i.e. `from == allowedFrom` and
    ///      `allowedFrom != borrower`), `fromSignature` must be a valid EIP-712 signature from
    ///      `allowedFrom` over the same LeverageAuth hash. Validated via
    ///      `SignatureChecker.isValidSignatureNow` (supports both ECDSA and EIP-1271), ensuring
    ///      that a Gnosis Safe's threshold of owners explicitly consents to the share deposit.
    /// @param auth The user's leverage authorization (tokenId, maxBorrow budget, nonce, deadline)
    /// @param authSignature Borrower's EIP-712 signature of the LeverageAuth
    /// @param fromSignature `allowedFrom`'s EIP-712 signature over the same LeverageAuth hash.
    ///                     Only required when pulling shares from `allowedFrom` (i.e. `data.from == allowedFrom`
    ///                     AND `allowedFrom != borrower` AND `data.depositAmount > 0`). Pass empty bytes otherwise.
    /// @param data Bundled call parameters (from, borrowTo, depositAmount, borrowAmount)
    /// @param priceData Signed oracle price data (required when borrowAmount > 0)
    function leverageDeposit(
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        bytes calldata fromSignature,
        LeverageDepositData calldata data,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        // Validate `from`: must be the user-signed allowedFrom OR the relayer itself
        if (data.from != auth.allowedFrom && data.from != relayer) revert InvalidAddress();
        // Validate `borrowTo`: same rule — either allowedFrom or relayer
        if (data.borrowTo != auth.allowedFrom && data.borrowTo != relayer) revert InvalidAddress();

        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > auth.deadline) revert IntentExpired();

        bytes32 structHash = keccak256(abi.encode(
            LEVERAGE_AUTH_TYPEHASH, auth.borrower, auth.allowedFrom, auth.tokenId,
            auth.maxBorrow, auth.nonce, auth.deadline
        ));
        bytes32 authHash = _hashTypedDataV4(structHash);
        // SignatureChecker supports contract-account borrowers (Safes) signing LeverageAuth via EIP-1271.
        if (!SignatureChecker.isValidSignatureNow(auth.borrower, authHash, authSignature)) revert InvalidIntentSignature();

        // Require `allowedFrom`'s explicit consent when pulling its CTF shares.
        // A borrower-only signature is insufficient — without this check, a user could sign
        // a LeverageAuth with their own key but set `allowedFrom` to any CTF-approved third party.
        if (data.depositAmount > 0 && data.from != relayer) {
            _verifyAllowedFromSig(auth.allowedFrom, auth.borrower, authHash, fromSignature);
        }

        _accrueInterest();

        if (data.depositAmount > 0) {
            // Deposit-only path (no borrow this round) consumes a one-shot per authHash slot.
            // Allowed at most once per auth and never after any borrow has been formalized.
            // Combined deposit+borrow calls (borrowAmount > 0) are gated by maxBorrow budget instead.
            if (data.borrowAmount == 0) {
                if (leverageBorrowUsed[authHash] > 0) revert AuthAlreadyUsed();
                if (leverageDepositOnlyConsumed[authHash]) revert AuthAlreadyUsed();
                leverageDepositOnlyConsumed[authHash] = true;
            }
            _depositCollateral(auth.borrower, data.from, auth.tokenId, data.depositAmount, data.depositAmount);
        }

        if (data.borrowAmount > 0) {
            // Consume nonce on first borrow, not on deposit-only calls (see NONCE DESIGN NatSpec above)
            bool isFirstBorrow = (leverageBorrowUsed[authHash] == 0);
            if (isFirstBorrow) {
                if (auth.nonce != leverageNonces[auth.borrower]) revert InvalidNonce();
                leverageNonces[auth.borrower]++;
            }

            // Settle pending advance (v1.5.0): advance was already counted in
            // leverageBorrowUsed by pullUsdcForLeverage, so only count the excess.
            uint256 advance = pendingAdvances[authHash];
            if (advance > 0) {
                uint256 settled = advance > data.borrowAmount ? data.borrowAmount : advance;
                pendingAdvances[authHash] = advance - settled;
                totalPendingAdvances -= settled;
                if (pendingAdvances[authHash] == 0) delete pendingAdvanceTimestamps[authHash];
                _advanceOffset = settled;
            }

            // Enforce cumulative borrow budget (advance portion already counted)
            uint256 effectiveNewBorrow = data.borrowAmount > advance ? data.borrowAmount - advance : 0;
            uint256 newTotal = leverageBorrowUsed[authHash] + effectiveNewBorrow;
            if (newTotal > auth.maxBorrow) revert ExceedsBorrowBudget();
            leverageBorrowUsed[authHash] = newTotal;

            if (priceData.tokenId != auth.tokenId) revert PredmartOracle.TokenIdMismatch();
            uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
            _executeBorrow(auth.borrower, auth.tokenId, data.borrowAmount, price, priceData.maxBorrow, data.borrowTo, isFirstBorrow);

            _advanceOffset = 0;
        }
    }

    // initiateClose moved to PredmartPoolExtension (EIP-170 size limit).
    // Called via fallback delegatecall — same function selector, transparent to callers.

    /// @dev Core borrow execution — shared by borrowViaRelay (USDC→EOA) and leverageDeposit (USDC→Safe).
    ///      Caller must call _accrueInterest() before this function.
    /// @param borrower Position owner
    /// @param tokenId Token ID of the position
    /// @param amount USDC to borrow (6 decimals)
    /// @param price Verified oracle price in WAD
    /// @param maxBorrowDepthCap Depth-gate borrow cap from oracle price data
    /// @param sendTo Address to receive borrowed USDC
    function _executeBorrow(
        address borrower, uint256 tokenId, uint256 amount,
        uint256 price, uint256 maxBorrowDepthCap, address sendTo,
        bool chargeFee
    ) internal {
        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        // Check LTV constraint
        uint256 currentDebt = pos.borrowShares > 0
            ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
            : 0;
        uint256 collateralValue = pos.collateralAmount.mulDiv(price, 1e18);
        uint256 ltv = getLTV(price);
        uint256 maxBorrow = collateralValue.mulDiv(ltv, 1e18);
        if (currentDebt + amount > maxBorrow) revert ExceedsLTV();
        if (currentDebt + amount < MIN_BORROW) revert BorrowTooSmall();

        // Per-token borrow cap
        if (poolCapBps > 0) {
            uint256 tokenCap = totalAssets().mulDiv(poolCapBps, 10000);
            if (totalBorrowedPerToken[tokenId] + amount > tokenCap) revert ExceedsTokenCap();
        }

        // Depth-gate cap
        if (totalBorrowedPerToken[tokenId] + amount > maxBorrowDepthCap) revert DepthCapExceeded();

        // Check liquidity (offset by advance already sent to relayer)
        uint256 offset = _advanceOffset;
        if (offset > amount) offset = amount; // Defensive: prevent underflow
        if (amount - offset > _availableCash()) revert InsufficientLiquidity();

        // Convert amount to borrow shares (round UP)
        uint256 shares = _toBorrowShares(amount, Math.Rounding.Ceil);

        // Update state
        pos.borrowShares += shares;
        pos.borrowedPrincipal += amount;
        totalBorrowAssets += amount;
        totalBorrowShares += shares;
        totalBorrowedPerToken[tokenId] += amount;

        // Track initial equity for profit fee (CEI pattern — must precede transfer).
        // First borrow: set initialEquity to net equity (collateralValue - totalDebt).
        // Subsequent borrows: reduce initialEquity by extracted USDC (amount - offset).
        // The leverage-advance portion (offset) does NOT reduce initialEquity because
        // pullUsdcForLeverage already credited userAmount; the offset is internal accounting.
        if (pos.initialEquity == 0) {
            uint256 totalDebt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            pos.initialEquity = collateralValue > totalDebt ? collateralValue - totalDebt : 0;
        } else {
            uint256 extracted = amount > offset ? amount - offset : 0;
            if (extracted > 0) {
                pos.initialEquity = pos.initialEquity > extracted ? pos.initialEquity - extracted : 0;
            }
        }

        // Transfer USDC (deduct operation fee + advance offset).
        // When offset > 0, fee was already charged in pullUsdcForLeverage — skip here.
        uint256 fee = (chargeFee && offset == 0) ? operationFee : 0;
        if (fee > 0) {
            operationFeePool += fee;
            emit OperationFeeCollected(borrower, fee);
        }
        uint256 deductions = fee + offset;
        uint256 toSend = amount > deductions ? amount - deductions : 0;
        if (toSend > 0) {
            IERC20(asset()).safeTransfer(sendTo, toSend);
        }

        emit Borrowed(borrower, tokenId, amount);
    }

    // repay() moved to PredmartPoolExtension (EIP-170 size limit)
    // Accessible at same address via fallback() → delegatecall

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    // NOTE: liquidate, resolveMarket, closeLostPosition, redeemWonCollateral, settleRedemption,
    // settleLiquidation, and expirePendingLiquidation have been moved to PredmartPoolExtension.
    // They are accessible at the same address via the fallback() → delegatecall pattern.
    //
    // v2.0.0: liquidate() uses full collateral seizure (seize-first, sell-second model).
    // Liquidator receives all shares, sells on CLOB, calls settleLiquidation() with proceeds.

    /*//////////////////////////////////////////////////////////////
                           RISK MODEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the LTV ratio for a given collateral price (piecewise linear interpolation)
    function getLTV(uint256 price) public view returns (uint256) {
        return PredmartPoolLib.interpolate(priceAnchors, ltvAnchors, price);
    }

    /// @notice Get the liquidation threshold for a given price (LTV + buffer)
    function getLiquidationThreshold(uint256 price) public view returns (uint256) {
        return getLTV(price) + PredmartPoolLib.LIQUIDATION_BUFFER;
    }

    /// @notice Get current pool utilization rate (uses stale assets to match accrual-time rate)
    function getUtilization() public view returns (uint256) {
        uint256 totalLiquidity = _totalAssetsStale();
        if (totalLiquidity == 0) return 0;
        return totalBorrowAssets.mulDiv(1e18, totalLiquidity);
    }

    /// @notice Get current borrow rate (all borrowers pay the same pool rate)
    function getBorrowRate() public view returns (uint256) {
        return PredmartPoolLib.calcBorrowRate(getUtilization());
    }

    /// @notice Health factor for a position (< 1e18 = liquidatable).
    function getHealthFactor(address borrower, uint256 tokenId, uint256 price) external view returns (uint256) {
        Position memory pos = positions[borrower][tokenId];
        if (pos.borrowShares == 0) return type(uint256).max;
        uint256 debt = _toBorrowAssetsView(pos.borrowShares, Math.Rounding.Ceil);
        return _getHealthFactor(pos.collateralAmount, debt, price);
    }

    /// @notice Total debt for a position (real-time, includes pending interest).
    function getPositionDebt(address borrower, uint256 tokenId) external view returns (uint256) {
        Position memory pos = positions[borrower][tokenId];
        if (pos.borrowShares == 0) return 0;
        return _toBorrowAssetsView(pos.borrowShares, Math.Rounding.Ceil);
    }

    /// @dev Internal health factor calculation (threshold is price-dependent: LTV + buffer)
    function _getHealthFactor(uint256 collateralAmount, uint256 debt, uint256 price) internal view returns (uint256) {
        return PredmartPoolLib.calcHealthFactor(collateralAmount, debt, price, getLiquidationThreshold(price));
    }

    /*////////////////////////////////////////////////////////////// 
                    ADMIN (kept in main)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the extension contract address. Only usable for initial deployment (extension unset)
    ///         or when the timelock is disabled. For rotating an already-set extension under an active
    ///         timelock, use `proposeExtension` + `executeExtension`.
    /// @dev During UUPS upgrades, `initializeVN()` can set the extension atomically via reinitializer,
    ///      bypassing the timelock as part of a governance-approved upgrade.
    function setExtension(address ext) external onlyAdmin {
        if (ext == address(0)) revert InvalidAddress();
        if (extension != address(0) && timelockDelay > 0) revert TimelockNotReady();
        extension = ext;
        emit ExtensionUpdated(ext);
    }

    /// @notice Propose a timelocked extension rotation. Takes effect after `timelockDelay` seconds
    ///         via `executeExtension()`. Calling again overwrites the pending proposal.
    /// @dev Kept in main pool (not extension) so it remains callable even if the current extension
    ///      itself is broken or reverting on every delegatecall.
    function proposeExtension(address ext) external onlyAdmin {
        if (ext == address(0)) revert InvalidAddress();
        pendingExtension = ext;
        pendingExtensionExecAfter = block.timestamp + timelockDelay;
        emit ExtensionChangeProposed(ext, pendingExtensionExecAfter);
    }

    /// @notice Execute a previously proposed extension rotation after the timelock elapses.
    function executeExtension() external onlyAdmin {
        if (pendingExtension == address(0)) revert NoPendingChange();
        if (block.timestamp < pendingExtensionExecAfter) revert TimelockNotReady();
        extension = pendingExtension;
        delete pendingExtension;
        delete pendingExtensionExecAfter;
        emit ExtensionUpdated(extension);
    }

    // setLeverageModule / proposeLeverageModule / executeLeverageModule /
    // cancelPendingLeverageModule moved to PredmartPoolExtension (EIP-170 size limit).
    // initializeV17 stays here — reinitializers must live in the upgrade target.

    // withdrawReserves moved to PredmartPoolExtension (EIP-170 size limit)

    /// @notice Get the current per-token borrow cap in USDC (6 decimals).
    function getTokenBorrowCap() external view returns (uint256) {
        if (poolCapBps == 0) return 0;
        return totalAssets().mulDiv(poolCapBps, 10000);
    }

    /*////////////////////////////////////////////////////////////// 
                          EXTENSION FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Delegate unknown function calls to the extension contract.
    ///      Reentrancy guard is implemented manually because the Solidity nonReentrant modifier
    ///      is incompatible with assembly return (return skips modifier cleanup, leaving the guard
    ///      permanently locked). Uses the same ERC-7201 storage slot as OZ ReentrancyGuard.
    fallback() external {
        address ext = extension;
        if (ext == address(0)) revert InvalidAddress();
        bytes32 guardSlot = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
        assembly {
            if eq(sload(guardSlot), 2) {
                mstore(0x00, 0x3ee5aeb5) // ReentrancyGuardReentrantCall()
                revert(0x1c, 0x04)
            }
            sstore(guardSlot, 2) // ENTERED
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            sstore(guardSlot, 1) // NOT_ENTERED
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /*////////////////////////////////////////////////////////////// 
                              UPGRADES
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorize contract upgrades — checks timelock if delay > 0
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {
        if (timelockDelay > 0) {
            if (newImplementation != pendingUpgrade) revert NoPendingChange();
            if (block.timestamp < pendingUpgradeExecAfter) revert TimelockNotReady();
            delete pendingUpgrade;
            delete pendingUpgradeExecAfter;
        }
    }

    // supportsInterface inherited from ERC1155Holder (no override needed — only one parent defines it)
}
