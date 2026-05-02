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
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import {
    Position, MarketResolution, Redemption, PendingClose, PendingLiquidation,
    NotAdmin, InvalidAddress, TimelockNotReady, NoPendingChange,
    InterestAccrued
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

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ProtocolPaused();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExtensionUpdated(address indexed newExtension);
    event ExtensionChangeProposed(address indexed newExtension, uint256 execAfter);
    event LeverageModuleUpdated(address indexed newModule);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    // Structs moved to PredmartBorrowExtension (borrow/leverage entries) and PredmartPoolExtension (close/lifecycle):
    //   BorrowIntent, WithdrawIntent, LeverageAuth, LeverageDepositData → PredmartBorrowExtension
    //   CloseAuth → PredmartPoolExtension

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
    uint256 public operationFee; // USDC (6 decimals). E.g. 10000 = $0.01
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

    // Leverage module + timelocked rotation. Set during the upgrade reinitializer;
    // rotated via proposeLeverageModule + executeLeverageModule on the extension.
    // The module is the sole authorized caller of pullUsdcForLeverage.
    // Public so callers can read pool state directly without going through the fallback.
    // Names match PredmartPoolExtension and PredmartBorrowExtension storage so the
    // delegatecall slot shape is identical.
    address public leverageModule;
    address public pendingLeverageModule;
    uint256 public pendingLeverageModuleExecAfter;

    // Selector → extension routing table populated by initializeV19. Rebound via
    // setExtensionSelectors (timelock-respecting once a binding exists).
    mapping(bytes4 => address) public extensionForSelector;

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

    // initializeV5-V18 removed — already executed on mainnet, reinitializer prevents reuse.
    // V1-V4 retained because test/deploy scripts use them for fresh-proxy setup.
    // Future upgrades MUST add a fresh `initializeVN` with `reinitializer(N)` for any new state setup.

    /// @notice V19 — V2-native architecture: split into PoolExtension (lifecycle) +
    ///         BorrowExtension (borrow/leverage entries). Populates the selector-routing
    ///         table so the new fallback knows where each function lives. Also rotates
    ///         the LeverageModule address to the V2-aware build that pulls pUSD.
    /// @dev    Must be called once during the upgrade tx (via upgradeToAndCall).
    /// @param  _poolExt          PredmartPoolExtension (lifecycle) address.
    /// @param  _borrowExt        PredmartBorrowExtension address.
    /// @param  _leverageModuleAddr V2-native PredmartLeverageModule (pulls pUSD with optional wrap-all).
    /// @param  _poolSelectors    Selectors that route to PoolExtension.
    /// @param  _borrowSelectors  Selectors that route to BorrowExtension.
    function initializeV19(
        address _poolExt,
        address _borrowExt,
        address _leverageModuleAddr,
        bytes4[] calldata _poolSelectors,
        bytes4[] calldata _borrowSelectors
    ) public reinitializer(19) {
        if (_poolExt == address(0)) revert InvalidAddress();
        if (_borrowExt == address(0)) revert InvalidAddress();
        if (_leverageModuleAddr == address(0)) revert InvalidAddress();

        // Legacy single-extension slot points to the lifecycle extension; the selector
        // routing mapping handles per-function dispatch. Any selector not registered
        // (e.g. forgotten in the upgrade payload) falls back to `extension` so an
        // incomplete migration still resolves to the prior behavior.
        extension = _poolExt;
        leverageModule = _leverageModuleAddr;

        for (uint256 i = 0; i < _poolSelectors.length; i++) {
            extensionForSelector[_poolSelectors[i]] = _poolExt;
        }
        for (uint256 i = 0; i < _borrowSelectors.length; i++) {
            extensionForSelector[_borrowSelectors[i]] = _borrowExt;
        }

        emit ExtensionUpdated(_poolExt);
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

    // ──────────────────────────────────────────────────────────────────
    // The following functions have been moved to PredmartBorrowExtension:
    //   borrowViaRelay, leverageDeposit, withdrawViaRelay,
    //   depositCollateralFrom, _executeBorrow, _verifyAllowedFromSig,
    //   _depositCollateral, _withdrawCollateral.
    // Reached via the selector-routed fallback() at the bottom of this file.
    // ──────────────────────────────────────────────────────────────────

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

    /// @dev Selector-routed fallback. Each function selector is mapped to either the
    ///      lifecycle extension (PoolExtension) or the borrow extension (BorrowExtension)
    ///      via `extensionForSelector`. Falls back to the legacy `extension` field for
    ///      any selector not explicitly routed (transitional behavior).
    fallback() external {
        address ext = extensionForSelector[msg.sig];
        if (ext == address(0)) ext = extension; // fallback for unrouted selectors
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

    /// @notice Bind a batch of selectors to a target extension. Timelock-respecting:
    ///         instant only when no extension is currently registered for the selector,
    ///         OR timelockDelay == 0 (bootstrap mode).
    function setExtensionSelectors(bytes4[] calldata selectors, address ext) external onlyAdmin {
        if (ext == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < selectors.length; i++) {
            address current = extensionForSelector[selectors[i]];
            if (current != address(0) && current != ext && timelockDelay > 0) {
                revert TimelockNotReady();
            }
            extensionForSelector[selectors[i]] = ext;
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
