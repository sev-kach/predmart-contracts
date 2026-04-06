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
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { ICTF } from "./interfaces/ICTF.sol";
import {
    Position, MarketResolution, Redemption, PendingClose,
    NotAdmin, InvalidAddress, NoPosition, TimelockNotReady, NoPendingChange, NotRelayer,
    BadDebtAbsorbed, InterestAccrued, PositionCloseInitiated, OperationFeeCollected
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

    string public constant VERSION = "1.3.0";

    uint256 public constant MAX_RELAY_PRICE_AGE = 10 seconds;
    uint256 public constant NUM_ANCHORS = 7;
    uint256 public constant MIN_BORROW = 1e6; // $1 USDC minimum debt
    uint256 public constant CLOSE_TIMEOUT = 1 hours; // Max duration for pending flash close settlement

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

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ProtocolPaused();
    error MarketResolved();
    error PositionHealthy();
    error ExceedsLTV();
    error InsufficientLiquidity();
    error TokenFrozen();
    error BorrowTooSmall();
    error ExceedsTokenCap();
    error DepthCapExceeded();
    error IntentExpired();
    error InvalidIntentSignature();
    error InvalidNonce();
    error NotProxyOwner();
    error ExceedsBorrowBudget();
    error PositionHasPendingClose();
    error NoPendingClose();
    error CloseNotExpired();
    error PositionUnhealthy();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event Borrowed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event Repaid(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 collateralSeized,
        uint256 debtRepaid
    );
    event ReservesWithdrawn(address indexed to, uint256 amount);
    event ExtensionUpdated(address indexed newExtension);

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

    /// @notice EIP-712 authorization for a leverage loop (signed once, reusable within budget)
    struct LeverageAuth {
        address borrower;
        address allowedFrom; // Permitted source for CTF shares (user's Safe for first loop, relayer always allowed via msg.sender)
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

    // v1.0.0 — Leverage loop authorization
    mapping(address => uint256) public leverageNonces; // Separate nonce for leverage (doesn't interfere with borrow/withdraw nonces)
    mapping(bytes32 => uint256) public leverageBorrowUsed; // authHash => cumulative USDC borrowed under this auth

    // v1.1.0 — DEPRECATED (kept for proxy storage layout — no public getter)
    mapping(address => uint256) internal deleverageNonces;
    mapping(bytes32 => uint256) internal deleverageWithdrawUsed;

    // v1.2.0 — Pool-funded flash close
    mapping(address => uint256) public closeNonces; // Separate nonce for flash close
    uint256 public totalPendingCloses; // Sum of all pending close debt amounts (USDC 6 decimal)
    mapping(address => mapping(uint256 => PendingClose)) public pendingCloses; // borrower => tokenId => pending

    // v1.3.0 — Flat fee for relayed operations (spam protection / relayer gas sustainability)
    uint256 public operationFee; // USDC (6 decimals). E.g. 30000 = $0.03
    uint256 public operationFeePool; // Accumulated USDC fees dedicated to relayer gas top-up
    mapping(uint256 => uint256) public feeSharesAccumulated; // tokenId => CTF shares collected as withdrawal fees

    // v1.5.0 — Single-step leverage: pool advances borrow USDC to relayer before collateral is deposited
    mapping(bytes32 => uint256) public pendingAdvances; // authHash => USDC advanced to relayer
    uint256 public totalPendingAdvances; // Global sum for liquidity monitoring
    uint256 private _advanceOffset; // Transient: used to pass advance offset to _executeBorrow

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

    /// @notice Initialize v0.1.0 (already called on existing proxies)
    /// @param _admin Admin address
    function initialize(address _admin) public initializer {
        admin = _admin;
    }

    /// @notice Initialize v0.2.0+ — called during UUPS upgrade
    /// @param _oracle Trusted oracle signer address
    /// @param _usdc USDC token address
    /// @param _ctf Polymarket CTF ERC-1155 contract address
    function initializeV2(address _oracle, address _usdc, address _ctf) public reinitializer(2) {
        __ERC20_init("Predmart USDC", "pUSDC");
        __ERC4626_init(IERC20(_usdc));

        oracle = _oracle;
        ctf = _ctf;

        // Default risk model anchors (prices in WAD)
        priceAnchors = [uint256(0), 0.10e18, 0.20e18, 0.40e18, 0.60e18, 0.80e18, 1.00e18];
        ltvAnchors = [uint256(0.02e18), 0.08e18, 0.30e18, 0.45e18, 0.60e18, 0.70e18, 0.75e18];
    }

    /// @notice Initialize v0.6.0 — sets per-token borrow cap (5% of pool per token)
    function initializeV3() public reinitializer(3) {
        poolCapBps = 500; // 5%
    }

    /// @notice Initialize v0.8.0 — EIP-712 domain + relayer for meta-transactions
    /// @param _relayer Trusted relayer address (backend's transaction sender)
    function initializeV4(address _relayer) public reinitializer(4) {
        __EIP712_init("Predmart Lending Pool", "0.8.0");
        relayer = _relayer;
    }

    /// @notice Initialize v1.0.0 — set extension address during UUPS upgrade
    /// @param _extension New extension contract address
    // initializeV5, V7, V8 removed — already executed, reinitializer prevents reuse

    /// @notice Initialize v1.5.0 — update extension (single-step leverage with pool advance)
    function initializeV9(address _extension) public reinitializer(9) {
        extension = _extension;
    }

    /*//////////////////////////////////////////////////////////////
                        GLOBAL INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Accrue interest on the entire borrow pool. Permissionless.
    function accrueInterest() external {
        _accrueInterest();
    }

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
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalBorrowAssets + totalPendingCloses + totalPendingAdvances;
        total = total > totalReserves ? total - totalReserves : 0;
        total = total > unsettledRedemptions ? total - unsettledRedemptions : 0;
        total = total > operationFeePool ? total - operationFeePool : 0;
        return total;
    }

    /// @dev Available USDC in the contract excluding reserves, unsettled redemptions, operation fees, and pending advances
    function _availableCash() internal view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        cash = cash > totalReserves ? cash - totalReserves : 0;
        cash = cash > unsettledRedemptions ? cash - unsettledRedemptions : 0;
        cash = cash > operationFeePool ? cash - operationFeePool : 0;
        cash = cash > totalPendingAdvances ? cash - totalPendingAdvances : 0;
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
    function depositCollateral(uint256 tokenId, uint256 amount) external nonReentrant whenNotPaused {
        _depositCollateral(msg.sender, msg.sender, tokenId, amount);
    }

    /// @notice Deposit collateral from a different address (e.g. Polymarket Safe proxy).
    ///         The `from` address must have approved this contract via setApprovalForAll.
    ///         Caller must be the `from` address itself or a registered owner of the Gnosis Safe at `from`.
    /// @param from Address holding the CTF shares (e.g. user's Gnosis Safe)
    /// @param tokenId Polymarket CTF token ID
    /// @param amount Number of shares to deposit
    function depositCollateralFrom(address from, uint256 tokenId, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != from) {
            (bool ok, bytes memory data) = from.staticcall(
                abi.encodeWithSignature("isOwner(address)", msg.sender)
            );
            if (!ok || data.length < 32 || !abi.decode(data, (bool))) revert NotProxyOwner();
        }
        _depositCollateral(msg.sender, from, tokenId, amount);
    }

    /// @dev Internal deposit: transfers CTF shares from `from` and credits the position to `creditTo`.
    ///      `creditTo` == `from` for direct deposits; `creditTo` != `from` for relay-based deposits
    ///      (e.g. leverage: relayer deposits from Safe, position credited to the EOA borrower).
    function _depositCollateral(address creditTo, address from, uint256 tokenId, uint256 amount) internal {
        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();
        if (pendingCloses[creditTo][tokenId].deadline != 0) revert PositionHasPendingClose();

        ICTF(ctf).safeTransferFrom(from, address(this), tokenId, amount, "");

        positions[creditTo][tokenId].collateralAmount += amount;

        emit CollateralDeposited(creditTo, tokenId, amount);
    }

    /// @notice Withdraw collateral via meta-transaction relay. Only callable by the relayer.
    function _verifyRelaySignature(
        address borrower,
        uint256 deadline,
        bytes32 structHash,
        bytes calldata signature
    ) internal view {
        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > deadline) revert IntentExpired();
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != borrower) revert InvalidIntentSignature();
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

        // Verify borrower's EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(
            WITHDRAW_INTENT_TYPEHASH, intent.borrower, intent.to, intent.tokenId,
            intent.amount, intent.nonce, intent.deadline
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), intentSignature);
        if (signer != intent.borrower) revert InvalidIntentSignature();

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

        // Verify price when: (a) user has debt (health check), or (b) relay fee is active
        uint256 price;
        if (pos.borrowShares > 0) {
            price = _verifyPriceFor(tokenId, priceData);
            uint256 debt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            if (_getHealthFactor(newCollateral, debt, price) < 1e18) revert ExceedsLTV();
        } else if (operationFee > 0 && msg.sender == relayer) {
            price = _verifyPriceFor(tokenId, priceData);
        }

        pos.collateralAmount = newCollateral;

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

        // Verify borrower's EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(
            BORROW_INTENT_TYPEHASH, intent.borrower, intent.tokenId, intent.amount, intent.nonce, intent.deadline
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), intentSignature);
        if (signer != intent.borrower) revert InvalidIntentSignature();

        // Consume nonce
        borrowNonces[intent.borrower]++;

        if (priceData.tokenId != intent.tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterest();
        _executeBorrow(intent.borrower, intent.tokenId, intent.amount, price, priceData.maxBorrow, intent.borrower, true);
    }

    /// @notice Execute one step of a leverage loop: deposit collateral + borrow USDC.
    /// @dev Only callable by the relayer. User must sign a LeverageAuth EIP-712 message authorizing
    ///      a maximum borrow budget. The contract verifies the signature and tracks cumulative borrowing
    ///      against the budget. The auth is consumed (nonce incremented) on first use and expires at deadline.
    ///      Borrowed USDC goes to auth.allowedFrom (user's Safe) so the user can buy shares on the CLOB.
    ///
    ///      NONCE DESIGN (LC-02): Nonce is consumed on first borrow, NOT on deposit-only calls.
    ///      This is intentional. A leverage loop is multi-step (deposit → borrow → deposit → borrow).
    ///      If the nonce were consumed on the first deposit-only step, the auth (signed with nonce N)
    ///      would be bricked — subsequent steps would fail because the contract expects nonce N+1.
    ///      Deposit-only replay is harmless: it only adds collateral (improving the borrower's HF).
    ///      The borrow budget (maxBorrow) prevents unbounded borrowing under a single auth.
    /// @param auth The user's leverage authorization (tokenId, maxBorrow budget, nonce, deadline)
    /// @param authSignature The user's EIP-712 signature of the LeverageAuth
    /// @param from Address holding CTF shares (user's Safe for first loop, relayer for subsequent loops)
    /// @param depositAmount Number of CTF shares to deposit as collateral (0 to skip deposit)
    /// @param borrowAmount USDC amount to borrow in this step (6 decimals, 0 to skip borrow)
    /// @param priceData Signed oracle price data (required when borrowAmount > 0)
    function leverageDeposit(
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        address from,
        address borrowTo,
        uint256 depositAmount,
        uint256 borrowAmount,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        // Validate `from`: must be the user-signed allowedFrom OR the relayer itself
        if (from != auth.allowedFrom && from != relayer) revert InvalidAddress();
        // Validate `borrowTo`: same rule — either allowedFrom or relayer
        if (borrowTo != auth.allowedFrom && borrowTo != relayer) revert InvalidAddress();

        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > auth.deadline) revert IntentExpired();

        bytes32 structHash = keccak256(abi.encode(
            LEVERAGE_AUTH_TYPEHASH, auth.borrower, auth.allowedFrom, auth.tokenId,
            auth.maxBorrow, auth.nonce, auth.deadline
        ));
        bytes32 authHash = _hashTypedDataV4(structHash);
        if (ECDSA.recover(authHash, authSignature) != auth.borrower) revert InvalidIntentSignature();

        _accrueInterest();

        if (depositAmount > 0) {
            _depositCollateral(auth.borrower, from, auth.tokenId, depositAmount);
        }

        if (borrowAmount > 0) {
            // Consume nonce on first borrow, not on deposit-only calls (see LC-02 NatSpec above)
            bool isFirstBorrow = (leverageBorrowUsed[authHash] == 0);
            if (isFirstBorrow) {
                if (auth.nonce != leverageNonces[auth.borrower]) revert InvalidNonce();
                leverageNonces[auth.borrower]++;
            }

            // Settle pending advance (v1.5.0): advance was already counted in
            // leverageBorrowUsed by pullUsdcForLeverage, so only count the excess.
            uint256 advance = pendingAdvances[authHash];
            if (advance > 0) {
                uint256 settled = advance > borrowAmount ? borrowAmount : advance;
                pendingAdvances[authHash] = advance - settled;
                totalPendingAdvances -= settled;
                _advanceOffset = settled;
            }

            // Enforce cumulative borrow budget (advance portion already counted)
            uint256 effectiveNewBorrow = borrowAmount > advance ? borrowAmount - advance : 0;
            uint256 newTotal = leverageBorrowUsed[authHash] + effectiveNewBorrow;
            if (newTotal > auth.maxBorrow) revert ExceedsBorrowBudget();
            leverageBorrowUsed[authHash] = newTotal;

            if (priceData.tokenId != auth.tokenId) revert PredmartOracle.TokenIdMismatch();
            uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
            _executeBorrow(auth.borrower, auth.tokenId, borrowAmount, price, priceData.maxBorrow, borrowTo, isFirstBorrow);

            _advanceOffset = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                     POOL-FUNDED FLASH CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Close an entire position in a single transaction. Pool absorbs the debt gap temporarily.
    /// @dev Flow: zero debt → send all collateral to relayer → relayer sells on CLOB → settleClose().
    ///      Shares go to msg.sender (relayer), NOT auth.allowedTo. This prevents the user from
    ///      receiving collateral and disappearing before repaying the pool.
    ///      Unhealthy positions (HF < 1.0) must use the liquidation flow, not flash close.
    ///      TRUST MODEL: The relayer is trusted to sell collateral honestly and call settleClose
    ///      with accurate saleProceeds. Relayer rotation is timelocked (6h) to allow detection.
    /// @param auth The user's close authorization (borrower, allowedTo for surplus, tokenId, nonce, deadline)
    /// @param authSignature The user's EIP-712 signature of the CloseAuth
    /// @param priceData Signed oracle price data
    function initiateClose(
        CloseAuth calldata auth,
        bytes calldata authSignature,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        if (auth.allowedTo == address(0)) revert InvalidAddress();
        if (msg.sender != relayer) revert NotRelayer();
        if (resolvedMarkets[auth.tokenId].resolved) revert MarketResolved();
        if (block.timestamp > auth.deadline) revert IntentExpired();
        if (auth.nonce != closeNonces[auth.borrower]) revert InvalidNonce();

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(
            CLOSE_AUTH_TYPEHASH, auth.borrower, auth.allowedTo, auth.tokenId, auth.nonce, auth.deadline
        ));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), authSignature);
        if (signer != auth.borrower) revert InvalidIntentSignature();

        // Consume nonce
        closeNonces[auth.borrower]++;

        // Block double close
        if (pendingCloses[auth.borrower][auth.tokenId].deadline != 0) revert PositionHasPendingClose();

        _accrueInterest();

        Position storage pos = positions[auth.borrower][auth.tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();
        if (pos.borrowShares == 0) revert NoPosition(); // No debt — use withdrawViaRelay instead

        uint256 collateralAmount = pos.collateralAmount;

        // Verify price and health
        uint256 price = _verifyPriceFor(auth.tokenId, priceData);
        uint256 debt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
        if (_getHealthFactor(collateralAmount, debt, price) < 1e18) revert PositionUnhealthy();

        // Zero the borrow
        uint256 principal = pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : debt;
        _reduceBorrowTracking(auth.tokenId, debt, pos.borrowShares, principal);
        pos.borrowShares = 0;
        pos.borrowedPrincipal = 0;

        // Record pending close — pool absorbs the gap until settlement
        pendingCloses[auth.borrower][auth.tokenId] = PendingClose({
            surplusRecipient: auth.allowedTo,
            debtAmount: debt,
            collateralAmount: collateralAmount,
            deadline: block.timestamp + CLOSE_TIMEOUT
        });
        totalPendingCloses += debt;

        // Withdraw all collateral to relayer (msg.sender) for CLOB sale
        pos.collateralAmount = 0;
        delete positions[auth.borrower][auth.tokenId];
        ICTF(ctf).safeTransferFrom(address(this), msg.sender, auth.tokenId, collateralAmount, "");

        emit PositionCloseInitiated(auth.borrower, auth.tokenId, debt, collateralAmount);
    }

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

    /// @notice Repay USDC debt for a position
    /// @param tokenId Token ID of the position to repay
    /// @param amount USDC amount to repay (6 decimals). Use type(uint256).max to repay all.
    function repay(uint256 tokenId, uint256 amount) external nonReentrant {
        _accrueInterest();

        Position storage pos = positions[msg.sender][tokenId];
        if (pos.borrowShares == 0) revert NoPosition();

        // Convert shares to current debt
        uint256 currentDebt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        // Determine shares to burn
        uint256 sharesToBurn;
        if (repayAmount == currentDebt) {
            // Full repayment — burn all shares to avoid dust
            sharesToBurn = pos.borrowShares;
        } else {
            // Partial repayment — round DOWN (borrower gets less credit)
            sharesToBurn = _toBorrowShares(repayAmount, Math.Rounding.Floor);
        }

        uint256 pr = pos.borrowedPrincipal == 0 ? repayAmount
            : sharesToBurn >= pos.borrowShares ? pos.borrowedPrincipal
            : pos.borrowedPrincipal.mulDiv(sharesToBurn, pos.borrowShares, Math.Rounding.Floor);
        pos.borrowedPrincipal = pos.borrowedPrincipal > pr ? pos.borrowedPrincipal - pr : 0;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repayAmount);

        pos.borrowShares -= sharesToBurn;
        _reduceBorrowTracking(tokenId, repayAmount, sharesToBurn, pr);

        emit Repaid(msg.sender, tokenId, repayAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidate an unhealthy position with partial close factor and capped incentives.
    /// @dev Two paths based on solvency:
    ///      ABOVE WATER (collateral >= debt): Partial liquidation. Liquidator repays up to closeFactor * debt,
    ///        receives repayAmount * (1 + 5% bonus) / price worth of collateral. Borrower keeps the rest.
    ///        Close factor = 50% if HF >= 0.95, 100% if HF < 0.95.
    ///      UNDERWATER (collateral < debt): Full liquidation. Liquidator pays 90% of collateral value,
    ///        receives all collateral. Bad debt (debt - payment) is socialized to lenders.
    /// @param borrower Address of the borrower to liquidate
    /// @param tokenId Token ID of the position to liquidate
    /// @param repayAmount Maximum USDC the liquidator is willing to repay (ignored for underwater)
    /// @param priceData Signed price data from oracle
    function liquidate(
        address borrower,
        uint256 tokenId,
        uint256 repayAmount,
        PredmartOracle.PriceData calldata priceData
    ) external nonReentrant whenNotPaused {
        if (msg.sender != relayer) revert NotRelayer();
        // Block liquidation on lost markets (shares worth $0 — liquidator would get worthless collateral).
        // Won markets stay liquidatable — ensures lenders can always recover debt.
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (resolution.resolved && !resolution.won) revert MarketResolved();
        if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterest();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        // Check position is unhealthy (health factor < 1.0)
        uint256 debt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
        uint256 healthFactor = _getHealthFactor(pos.collateralAmount, debt, price);
        if (healthFactor >= 1e18) revert PositionHealthy();

        PredmartPoolLib.LiquidationVars memory vars = PredmartPoolLib.calcLiquidation(
            pos.collateralAmount, debt, healthFactor, price, repayAmount
        );

        // Determine borrow shares to burn
        uint256 sharesToBurn;
        if (vars.repayAmount >= debt) {
            sharesToBurn = pos.borrowShares;
            vars.repayAmount = debt;
        } else {
            sharesToBurn = _toBorrowShares(vars.repayAmount, Math.Rounding.Floor);
        }

        uint256 pr = pos.borrowedPrincipal == 0 ? vars.repayAmount
            : sharesToBurn >= pos.borrowShares ? pos.borrowedPrincipal
            : pos.borrowedPrincipal.mulDiv(sharesToBurn, pos.borrowShares, Math.Rounding.Floor);
        pos.borrowedPrincipal = pos.borrowedPrincipal > pr ? pos.borrowedPrincipal - pr : 0;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), vars.liquidatorCost);

        pos.borrowShares -= sharesToBurn;
        pos.collateralAmount -= vars.seizeCollateral;
        _reduceBorrowTracking(tokenId, vars.repayAmount, sharesToBurn, pr);

        // Residual bad debt: collateral gone but debt remains
        if (pos.collateralAmount == 0 && pos.borrowShares > 0) {
            uint256 residualDebt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            uint256 rp = pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : residualDebt;
            pos.borrowedPrincipal = 0;
            _reduceBorrowTracking(tokenId, residualDebt, pos.borrowShares, rp);
            vars.badDebt += residualDebt;
            pos.borrowShares = 0;
        }

        // Clean up empty position
        if (pos.collateralAmount == 0 && pos.borrowShares == 0) {
            delete positions[borrower][tokenId];
        }

        // Transfer collateral to liquidator
        ICTF(ctf).safeTransferFrom(address(this), msg.sender, tokenId, vars.seizeCollateral, "");

        emit Liquidated(msg.sender, borrower, tokenId, vars.seizeCollateral, vars.liquidatorCost);
        if (vars.badDebt > 0) emit BadDebtAbsorbed(borrower, tokenId, vars.badDebt);
    }

    // NOTE: resolveMarket, closeLostPosition, redeemWonCollateral, and settleRedemption
    // have been moved to PredmartPoolExtension to free main contract bytecode space.
    // They are accessible at the same address via the fallback() → delegatecall pattern.

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

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the health factor for a position (includes pending interest in debt calculation)
    /// @param borrower Borrower address
    /// @param tokenId Token ID
    /// @param price Current price in WAD
    /// @return Health factor in WAD (< 1e18 = liquidatable)
    function getHealthFactor(address borrower, uint256 tokenId, uint256 price) external view returns (uint256) {
        Position memory pos = positions[borrower][tokenId];
        if (pos.borrowShares == 0) return type(uint256).max;
        uint256 debt = _toBorrowAssetsView(pos.borrowShares, Math.Rounding.Ceil);
        return _getHealthFactor(pos.collateralAmount, debt, price);
    }

    /// @notice Get the total debt for a position (real-time value including pending interest)
    /// @param borrower Borrower address
    /// @param tokenId Token ID
    /// @return Current debt in USDC (6 decimals)
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

    /// @notice Set the extension contract address (admin functions delegate to it).
    ///         Timelocked when extension is already set — prevents instant malicious swap.
    ///         During upgrades, use initializeVN() to set extension (bypasses via reinitializer).
    function setExtension(address ext) external onlyAdmin {
        if (ext == address(0)) revert InvalidAddress();
        if (extension != address(0) && timelockDelay > 0) revert TimelockNotReady();
        extension = ext;
        emit ExtensionUpdated(ext);
    }

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

    /*//////////////////////////////////////////////////////////////
                          ERC-165 OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolve supportsInterface conflict between ERC1155Holder and ERC4626Upgradeable
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
