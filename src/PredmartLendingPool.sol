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

    string internal constant VERSION = "0.9.1";

    uint256 public constant MAX_RELAY_PRICE_AGE = 10 seconds;
    uint256 public constant MAX_RESOLUTION_AGE = 1 hours;
    uint256 public constant NUM_ANCHORS = 7;
    uint256 public constant MIN_BORROW = 1e6; // $1 USDC minimum debt

    // EIP-712 typehashes for meta-transaction intents
    bytes32 public constant BORROW_INTENT_TYPEHASH = keccak256(
        "BorrowIntent(address borrower,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH = keccak256(
        "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error ProtocolPaused();
    error InvalidAddress();
    error NoPosition();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error MarketResolved();
    error PositionHealthy();
    error ExceedsLTV();
    error InsufficientLiquidity();
    error TokenFrozen();
    error TokenNotRedeemed();
    error AlreadyRedeemed();
    error RedemptionFailed();
    error TimelockNotReady();
    error NoPendingChange();
    error BorrowTooSmall();
    error ExceedsTokenCap();
    error DepthCapExceeded();
    error NotRelayer();
    error IntentExpired();
    error InvalidIntentSignature();
    error InvalidNonce();
    error NotProxyOwner();

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
    event MarketResolvedEvent(uint256 indexed tokenId, bool won);
    event PositionClosed(address indexed borrower, uint256 indexed tokenId, uint256 badDebt);
    event BadDebtAbsorbed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 reserve);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AnchorsUpdated();
    event ReservesWithdrawn(address indexed to, uint256 amount);
    event PausedStateChanged(bool paused);
    event TokenFrozenEvent(uint256 indexed tokenId, bool frozen);
    event CollateralRedeemed(uint256 indexed tokenId, uint256 sharesRedeemed, uint256 usdcReceived);
    event RedemptionSettled(address indexed borrower, uint256 indexed tokenId, uint256 debtRepaid, uint256 surplusToUser);
    event TimelockActivated(uint256 delay);
    event OracleChangeProposed(address indexed newOracle, uint256 executeAfter);
    event OracleChangeCancelled();
    event AnchorsChangeProposed(uint256 executeAfter);
    event AnchorsChangeCancelled();
    event UpgradeProposed(address indexed newImplementation, uint256 executeAfter);
    event UpgradeCancelled();
    event PoolCapUpdated(uint256 newCapBps);
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event ExtensionUpdated(address indexed newExtension);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Position {
        uint256 collateralAmount; // ERC-1155 shares deposited
        uint256 borrowShares; // Shares of the global borrow pool owned by this position
        uint256 lastDepositTimestamp; // DEPRECATED — kept for storage layout compatibility
        uint256 borrowedPrincipal; // v0.9.1 — cumulative USDC principal borrowed (for accurate per-token cap tracking)
    }

    struct MarketResolution {
        bool resolved;
        bool won;
    }

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
    struct Redemption {
        bool redeemed;
        uint256 totalShares; // Total CTF shares redeemed
        uint256 usdcReceived; // Actual USDC received from CTF
    }
    mapping(uint256 => Redemption) public redeemedTokens; // tokenId => redemption details
    uint256 public unsettledRedemptions; // USDC received from CTF redemptions but not yet settled against positions

    // Timelock — ratchet (can only increase, never decrease)
    uint256 public timelockDelay; // 0 = no timelock (dev mode), set to 24h+ for production

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

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    function _checkAdmin() internal view {
        if (msg.sender != admin) revert NotAdmin();
    }

    function _checkNotPaused() internal view {
        if (paused) revert ProtocolPaused();
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

    /*//////////////////////////////////////////////////////////////
                        GLOBAL INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Accrue interest on the entire borrow pool. Permissionless.
    function accrueInterest() external {
        _accrueInterest();
    }

    /// @dev Accrue interest on the entire borrow pool. Called before every state-changing operation.
    /// All borrowers' debt grows proportionally through the totalBorrowAssets/totalBorrowShares ratio.
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
        uint256 total = IERC20(asset()).balanceOf(address(this)) + totalBorrowAssets;
        total = total > totalReserves ? total - totalReserves : 0;
        total = total > unsettledRedemptions ? total - unsettledRedemptions : 0;
        return total;
    }

    /// @dev Available USDC in the contract excluding reserves and unsettled redemptions
    function _availableCash() internal view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        cash = cash > totalReserves ? cash - totalReserves : 0;
        cash = cash > unsettledRedemptions ? cash - unsettledRedemptions : 0;
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

    /// @dev Add reentrancy protection + global interest accrual to deposit
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueInterest();
        return super.deposit(assets, receiver);
    }

    /// @dev Add reentrancy protection + global interest accrual to mint
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
        _depositCollateral(msg.sender, tokenId, amount);
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
        _depositCollateral(from, tokenId, amount);
    }

    function _depositCollateral(address from, uint256 tokenId, uint256 amount) internal {
        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();

        ICTF(ctf).safeTransferFrom(from, address(this), tokenId, amount, "");

        positions[msg.sender][tokenId].collateralAmount += amount;

        emit CollateralDeposited(msg.sender, tokenId, amount);
    }

    /// @notice Withdraw collateral via meta-transaction relay. Only callable by the relayer.
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
        if (pos.borrowShares > 0) {
            // Has debt — verify price and check position stays healthy after withdrawal
            if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
            uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
            uint256 debt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            if (_getHealthFactor(newCollateral, debt, price) < 1e18) revert ExceedsLTV();
        }
        // No debt — skip price verification, user can freely withdraw their collateral

        pos.collateralAmount = newCollateral;
        ICTF(ctf).safeTransferFrom(address(this), to, tokenId, amount, "");

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

        // Standard borrow checks
        if (frozenTokens[intent.tokenId]) revert TokenFrozen();
        if (priceData.tokenId != intent.tokenId) revert PredmartOracle.TokenIdMismatch();
        if (resolvedMarkets[intent.tokenId].resolved) revert MarketResolved();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterest();

        Position storage pos = positions[intent.borrower][intent.tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        // Check LTV constraint
        uint256 currentDebt = pos.borrowShares > 0
            ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
            : 0;
        uint256 collateralValue = pos.collateralAmount.mulDiv(price, 1e18);
        uint256 ltv = getLTV(price);
        uint256 maxBorrow = collateralValue.mulDiv(ltv, 1e18);
        if (currentDebt + intent.amount > maxBorrow) revert ExceedsLTV();
        if (currentDebt + intent.amount < MIN_BORROW) revert BorrowTooSmall();

        // Per-token borrow cap
        if (poolCapBps > 0) {
            uint256 tokenCap = totalAssets().mulDiv(poolCapBps, 10000);
            if (totalBorrowedPerToken[intent.tokenId] + intent.amount > tokenCap) revert ExceedsTokenCap();
        }

        // Depth-gate cap
        if (totalBorrowedPerToken[intent.tokenId] + intent.amount > priceData.maxBorrow) revert DepthCapExceeded();

        // Check liquidity
        if (intent.amount > _availableCash()) revert InsufficientLiquidity();

        // Convert amount to borrow shares (round UP)
        uint256 shares = _toBorrowShares(intent.amount, Math.Rounding.Ceil);

        // Update state
        pos.borrowShares += shares;
        pos.borrowedPrincipal += intent.amount;
        totalBorrowAssets += intent.amount;
        totalBorrowShares += shares;
        totalBorrowedPerToken[intent.tokenId] += intent.amount;

        // Transfer USDC to borrower (not to relayer!)
        IERC20(asset()).safeTransfer(intent.borrower, intent.amount);

        emit Borrowed(intent.borrower, intent.tokenId, intent.amount);
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
    ) external nonReentrant {
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

    /*//////////////////////////////////////////////////////////////
                         MARKET RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Mark a Polymarket market as resolved. Permissionless — anyone can submit signed resolution data.
    /// @param tokenId Token ID of the resolved market
    /// @param data Signed resolution data from oracle
    function resolveMarket(uint256 tokenId, PredmartOracle.ResolutionData calldata data) external {
        if (resolvedMarkets[tokenId].resolved) revert MarketAlreadyResolved();
        if (data.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();

        bool won = PredmartOracle.verifyResolution(data, oracle, address(this), MAX_RESOLUTION_AGE);
        resolvedMarkets[tokenId] = MarketResolution({ resolved: true, won: won });

        emit MarketResolvedEvent(tokenId, won);
    }

    /// @notice Close a position in a resolved market. Anyone can call.
    /// @dev If won: position stays open — borrower repays, then withdraws collateral redeemable at $1.
    ///      If lost: writes off debt as bad debt, socializing the loss across all lenders.
    /// @param borrower Address of the borrower
    /// @param tokenId Token ID of the resolved market
    function closeResolvedPosition(address borrower, uint256 tokenId) external nonReentrant {
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved) revert MarketNotResolved();

        _accrueInterest();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        if (resolution.won) {
            emit PositionClosed(borrower, tokenId, 0);
        } else {
            // Losing shares worth $0 — write off bad debt
            uint256 badDebt = pos.borrowShares > 0
                ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
                : 0;
            if (pos.borrowShares > 0) {
                _reduceBorrowTracking(tokenId, badDebt, pos.borrowShares,
                    pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : badDebt);
            }
            delete positions[borrower][tokenId];
            if (badDebt > 0) emit BadDebtAbsorbed(borrower, tokenId, badDebt);
            emit PositionClosed(borrower, tokenId, badDebt);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       CTF REDEMPTION & SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeem winning CTF shares for USDC. Permissionless — anyone can call after market resolves won.
    /// @dev Calls Polymarket CTF redeemPositions(). Burns ALL pool's shares for this tokenId, receives USDC.
    ///      The conditionId is verified implicitly: if wrong, the pool's tokenId balance won't decrease and the call reverts.
    /// @param tokenId Token ID of the won market
    /// @param conditionId Polymarket condition ID (needed by CTF — cannot be derived from tokenId on-chain)
    /// @param indexSet Index set for this outcome (1 for Yes, 2 for No in binary markets)
    function redeemWonCollateral(uint256 tokenId, bytes32 conditionId, uint256 indexSet) external nonReentrant {
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved || !resolution.won) revert MarketNotResolved();
        if (redeemedTokens[tokenId].redeemed) revert AlreadyRedeemed();

        uint256 sharesBefore = ICTF(ctf).balanceOf(address(this), tokenId);
        uint256 usdcBefore = IERC20(asset()).balanceOf(address(this));

        // Call CTF redeemPositions — redeems all shares for this condition
        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = indexSet;
        ICTF(ctf).redeemPositions(asset(), bytes32(0), conditionId, indexSets);

        uint256 sharesAfter = ICTF(ctf).balanceOf(address(this), tokenId);
        uint256 usdcAfter = IERC20(asset()).balanceOf(address(this));

        // Verify our tokenId shares were actually redeemed (validates conditionId + indexSet)
        if (sharesAfter >= sharesBefore) revert RedemptionFailed();

        uint256 sharesRedeemed = sharesBefore - sharesAfter;
        uint256 usdcReceived = usdcAfter - usdcBefore;
        redeemedTokens[tokenId] = Redemption(true, sharesRedeemed, usdcReceived);
        unsettledRedemptions += usdcReceived;

        emit CollateralRedeemed(tokenId, sharesRedeemed, usdcReceived);
    }

    /// @notice Settle a borrower's position after CTF redemption. Permissionless — anyone can call.
    /// @dev Repays debt from redemption proceeds (winning shares = $1 each, so proceeds = collateralAmount).
    ///      Any surplus after debt repayment is sent to the borrower.
    /// @param borrower Address of the borrower
    /// @param tokenId Token ID of the redeemed market
    function settleRedemption(address borrower, uint256 tokenId) external nonReentrant {
        Redemption storage redemption = redeemedTokens[tokenId];
        if (!redemption.redeemed) revert TokenNotRedeemed();

        _accrueInterest();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        // Pro-rata proceeds: borrower's share of actual USDC received
        uint256 proceeds = pos.collateralAmount.mulDiv(redemption.usdcReceived, redemption.totalShares, Math.Rounding.Floor);
        uint256 debt = pos.borrowShares > 0
            ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
            : 0;

        // Clear borrow tracking
        if (pos.borrowShares > 0) {
            _reduceBorrowTracking(tokenId, debt, pos.borrowShares,
                pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : debt);
        }

        // Reduce unsettled redemptions by actual proceeds used
        unsettledRedemptions = unsettledRedemptions > proceeds ? unsettledRedemptions - proceeds : 0;

        // Calculate surplus for borrower (proceeds - debt)
        uint256 surplus = proceeds > debt ? proceeds - debt : 0;
        if (debt > proceeds) emit BadDebtAbsorbed(borrower, tokenId, debt - proceeds);
        delete positions[borrower][tokenId];

        // Send surplus to borrower
        if (surplus > 0) {
            IERC20(asset()).safeTransfer(borrower, surplus);
        }

        emit RedemptionSettled(borrower, tokenId, debt, surplus);
    }

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
    ///         Only callable when extension is not yet set (bootstrap) or during upgradeToAndCall callback.
    function setExtension(address ext) external onlyAdmin {
        if (ext == address(0)) revert InvalidAddress();
        if (extension != address(0) && timelockDelay > 0) revert TimelockNotReady();
        extension = ext;
        emit ExtensionUpdated(ext);
    }

    /// @notice Withdraw accumulated protocol reserves
    function withdrawReserves(uint256 amount) external onlyAdmin {
        _accrueInterest();
        if (amount > totalReserves) amount = totalReserves;
        totalReserves -= amount;
        IERC20(asset()).safeTransfer(admin, amount);
        emit ReservesWithdrawn(admin, amount);
    }

    /// @notice Get the current per-token borrow cap in USDC (6 decimals).
    function getTokenBorrowCap() external view returns (uint256) {
        if (poolCapBps == 0) return 0;
        return totalAssets().mulDiv(poolCapBps, 10000);
    }

    /*////////////////////////////////////////////////////////////// 
                          EXTENSION FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @dev Delegate unknown function calls to the extension contract.
    fallback() external {
        address ext = extension;
        if (ext == address(0)) revert InvalidAddress();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
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
