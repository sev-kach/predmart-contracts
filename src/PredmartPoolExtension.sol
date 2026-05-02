// SPDX-License-Identifier: MIT
// contracts/src/PredmartPoolExtension.sol
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { ICTF } from "./interfaces/ICTF.sol";
import { INegRiskAdapter } from "./interfaces/INegRiskAdapter.sol";
import {
    Position, MarketResolution, Redemption, PendingClose, PendingLiquidation,
    NotAdmin, InvalidAddress, NoPosition, TimelockNotReady, NoPendingChange, NotRelayer, NoPendingLiquidation, NotLiquidator, TokenFrozen,
    BadDebtAbsorbed, InterestAccrued, OperationFeeCollected, OperationFeeUpdated, LiquidationSettled, ProfitFeeCollected,
    PositionCloseInitiated, Repaid, CollateralDeposited
} from "./PredmartTypes.sol";

/// @title PredmartPoolExtension
/// @notice Admin and governance functions for PredmartLendingPool.
///         Called via delegatecall from the main contract's fallback() — shares the same storage.
///         This pattern keeps the main contract under the 24 KB EIP-170 size limit.
/// @dev CRITICAL: State variables MUST be in the exact same order as PredmartLendingPool.
///      OZ 5.x upgradeable contracts use ERC-7201 namespaced storage (no regular slots),
///      so custom variables start at slot 0 in both contracts.
contract PredmartPoolExtension {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant NUM_ANCHORS = 7;
    uint256 public constant MAX_RESOLUTION_AGE = 1 hours;
    uint256 public constant MAX_OPERATION_FEE = 100_000; // $0.10 USDC maximum
    uint256 public constant CLOSE_TIMEOUT = 48 hours;
    uint256 public constant MAX_RELAY_PRICE_AGE = 60 seconds;
    uint256 public constant MAX_TIMELOCK_DELAY = 10 days;
    bytes32 public constant CLOSE_AUTH_TYPEHASH = keccak256(
        "CloseAuth(address borrower,address allowedTo,uint256 tokenId,uint256 nonce,uint256 deadline)"
    );

    /// @notice Polymarket V2 pUSD token. Used for two-token settle close (surplus to user as pUSD).
    ///         Hardcoded to Polygon mainnet; redeploy for other networks.
    address public constant PUSD = 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAnchors();
    error TimelockCannotDecrease();
    error TimelockExceedsMaximum();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error TokenNotRedeemed();
    error AlreadyRedeemed();
    error RedemptionFailed();
    error UseRedemptionFlow();
    error NoPendingClose();
    error NoPendingAdvance();
    error CloseNotExpired();
    error FeeTooHigh();
    error MarketResolved();
    error PositionHealthy();
    error PositionUnhealthy();
    error PositionHasPendingClose();
    error ProtocolPaused();
    error TooEarly();
    error SettleAmountMismatch();
    error InvalidAmount();
    // Errors for initiateClose
    error IntentExpired();
    error InvalidIntentSignature();
    error InvalidNonce();

    event Liquidated(address indexed liquidator, address indexed borrower, uint256 indexed tokenId, uint256 collateralSeized, uint256 debtAmount);

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event PausedStateChanged(bool paused);
    event TokenFrozenEvent(uint256 indexed tokenId, bool frozen);
    event PoolCapUpdated(uint256 newCapBps);
    event TimelockActivated(uint256 delay);
    event OracleChangeProposed(address indexed newOracle, uint256 executeAfter);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event OracleChangeCancelled();
    event AnchorsChangeProposed(uint256 executeAfter);
    event AnchorsUpdated();
    event AnchorsChangeCancelled();
    event UpgradeProposed(address indexed newImplementation, uint256 executeAfter);
    event UpgradeCancelled();
    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event RelayerChangeProposed(address indexed newRelayer, uint256 executeAfter);
    event AdminTransferProposed(address indexed newAdmin, uint256 executeAfter);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event AdminTransferCancelled();
    event MarketResolvedEvent(uint256 indexed tokenId, bool won);
    event PositionClosed(address indexed borrower, uint256 indexed tokenId, uint256 badDebt);
    event CollateralRedeemed(uint256 indexed tokenId, uint256 sharesRedeemed, uint256 usdcReceived);
    event RedemptionSettled(address indexed borrower, uint256 indexed tokenId, uint256 debtRepaid, uint256 surplusToUser);
    event CloseSettled(address indexed borrower, uint256 indexed tokenId, uint256 repaid, uint256 badDebt, uint256 surplus);
    event CloseExpired(address indexed borrower, uint256 indexed tokenId, uint256 badDebt);

    /*//////////////////////////////////////////////////////////////
              STATE — MUST MATCH PredmartLendingPool EXACTLY
              (Shared structs imported from PredmartTypes.sol)
    //////////////////////////////////////////////////////////////*/

    // SLOT 0+
    address public admin;
    address public oracle;
    address public ctf;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrualTimestamp;
    uint256 public totalReserves;
    uint256[NUM_ANCHORS] public priceAnchors;
    uint256[NUM_ANCHORS] public ltvAnchors;
    mapping(address => mapping(uint256 => Position)) public positions;
    mapping(uint256 => MarketResolution) public resolvedMarkets;
    mapping(uint256 => bool) public frozenTokens;
    bool public paused;
    mapping(uint256 => Redemption) public redeemedTokens;
    uint256 public unsettledRedemptions;
    uint256 public timelockDelay; // PRODUCTION: 6h active (21600s). Persists across upgrades.
    address public pendingOracle;
    uint256 public pendingOracleExecAfter;
    uint256[NUM_ANCHORS] public pendingPriceAnchors;
    uint256[NUM_ANCHORS] public pendingLtvAnchors;
    uint256 public pendingAnchorsExecAfter;
    address public pendingUpgrade;
    uint256 public pendingUpgradeExecAfter;
    mapping(uint256 => uint256) public totalBorrowedPerToken;
    uint256 public poolCapBps;
    address public relayer;
    mapping(address => uint256) public borrowNonces;
    address public pendingRelayer;
    uint256 public pendingRelayerExecAfter;
    mapping(address => uint256) public withdrawNonces;
    address public extension; // v0.9.1 — extension contract address
    address public pendingAdmin; // v0.9.1 — timelocked admin transfer
    uint256 public pendingAdminExecAfter;

    // v1.0.0 — Leverage (must match PredmartLendingPool storage layout)
    mapping(address => uint256) public leverageNonces;
    mapping(bytes32 => uint256) public leverageBorrowUsed;

    // v1.1.0 — DEPRECATED (kept for proxy storage layout — no public getter)
    mapping(address => uint256) internal deleverageNonces;
    mapping(bytes32 => uint256) internal deleverageWithdrawUsed;

    // v1.2.0 — Pool-funded flash close (v1.6.0: per-position nonces, must match PredmartLendingPool)
    mapping(address => mapping(uint256 => uint256)) public closeNonces;
    uint256 public totalPendingCloses;
    mapping(address => mapping(uint256 => PendingClose)) public pendingCloses;

    // v1.3.0 — Operation fee (must match PredmartLendingPool storage layout)
    uint256 public operationFee;
    uint256 public operationFeePool;
    mapping(uint256 => uint256) public feeSharesAccumulated;

    // v1.5.0 — Leverage advance (must match PredmartLendingPool storage layout)
    mapping(bytes32 => uint256) public pendingAdvances;
    uint256 public totalPendingAdvances;
    uint256 private _advanceOffset;

    // v1.7.0 — NegRisk support
    address public negRiskAdapter;

    // v2.0.0 — Pending liquidations (seize-first model, must match PredmartLendingPool)
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

    // v2.3.0 — EIP-1271 signature auth for depositCollateralFrom (MUST mirror PredmartLendingPool storage layout)
    mapping(address => uint256) public depositCollateralFromNonces;

    // v2.3.1 — Timelocked extension rotation (MUST mirror PredmartLendingPool storage layout)
    address public pendingExtension;
    uint256 public pendingExtensionExecAfter;

    // v2.4.0 — Deposit-only call replay tracking (MUST mirror PredmartLendingPool storage layout)
    mapping(bytes32 => bool) public leverageDepositOnlyConsumed;

    // v2.5.0 — Atomic-execute leverage module + timelocked rotation
    //          (MUST mirror PredmartLendingPool storage layout)
    address public leverageModule;
    address public pendingLeverageModule;
    uint256 public pendingLeverageModuleExecAfter;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }


    /*//////////////////////////////////////////////////////////////
                      ADMIN — INSTANT (safe operations)
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose admin transfer. Takes effect after timelock delay.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        if (timelockDelay == 0) {
            // Bootstrap: instant transfer when no timelock. Emit AdminTransferred for off-chain observability.
            emit AdminTransferred(admin, newAdmin);
            admin = newAdmin;
        } else {
            pendingAdmin = newAdmin;
            pendingAdminExecAfter = block.timestamp + timelockDelay;
            emit AdminTransferProposed(newAdmin, pendingAdminExecAfter);
        }
    }

    /// @notice Execute a pending admin transfer after timelock.
    function executeTransferAdmin() external onlyAdmin {
        if (pendingAdmin == address(0)) revert NoPendingChange();
        if (block.timestamp < pendingAdminExecAfter) revert TimelockNotReady();
        emit AdminTransferred(admin, pendingAdmin);
        admin = pendingAdmin;
        delete pendingAdmin;
        delete pendingAdminExecAfter;
    }

    /// @notice Cancel a pending admin transfer.
    function cancelTransferAdmin() external onlyAdmin {
        delete pendingAdmin;
        delete pendingAdminExecAfter;
        emit AdminTransferCancelled();
    }

    /// @notice Freeze or unfreeze a specific token
    function setTokenFrozen(uint256 tokenId, bool frozen) external onlyAdmin {
        frozenTokens[tokenId] = frozen;
        emit TokenFrozenEvent(tokenId, frozen);
    }

    /// @notice Pause or unpause the protocol.
    /// Pause: callable by admin or relayer (emergency brake).
    /// Unpause: admin only.
    function setPaused(bool _paused) external {
        if (_paused) {
            if (msg.sender != admin && msg.sender != relayer) revert NotAdmin();
        } else {
            if (msg.sender != admin) revert NotAdmin();
        }
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /// @notice Set per-token borrow cap as basis points of totalAssets
    function setPoolCapBps(uint256 newCapBps) external onlyAdmin {
        poolCapBps = newCapBps;
        emit PoolCapUpdated(newCapBps);
    }

    event LiquidatorUpdated(address indexed oldLiquidator, address indexed newLiquidator);
    event LiquidatorChangeProposed(address indexed proposed, uint256 execAfter);
    event LiquidatorChangeCancelled();
    event LeverageModuleUpdated(address indexed newModule);
    event LeverageModuleChangeProposed(address indexed newModule, uint256 execAfter);
    event LeverageModuleChangeCancelled();

    /// @notice Set the leverage module address. Instant only when no module is set yet
    ///         OR the timelock is disabled. Otherwise use `proposeLeverageModule` +
    ///         `executeLeverageModule`.
    /// @dev    During UUPS upgrades, `initializeV17` sets it atomically via the
    ///         reinitializer, bypassing this timelock as part of a governance-approved
    ///         upgrade.
    function setLeverageModule(address mod) external onlyAdmin {
        if (mod == address(0)) revert InvalidAddress();
        if (timelockDelay > 0 && leverageModule != address(0)) revert TimelockNotReady();
        leverageModule = mod;
        emit LeverageModuleUpdated(mod);
    }

    /// @notice Propose a timelocked leverage-module rotation.
    function proposeLeverageModule(address mod) external onlyAdmin {
        if (mod == address(0)) revert InvalidAddress();
        pendingLeverageModule = mod;
        pendingLeverageModuleExecAfter = block.timestamp + timelockDelay;
        emit LeverageModuleChangeProposed(mod, pendingLeverageModuleExecAfter);
    }

    /// @notice Execute a previously proposed leverage-module rotation after timelock elapses.
    function executeLeverageModule() external onlyAdmin {
        if (pendingLeverageModule == address(0)) revert NoPendingChange();
        if (block.timestamp < pendingLeverageModuleExecAfter) revert TimelockNotReady();
        leverageModule = pendingLeverageModule;
        delete pendingLeverageModule;
        delete pendingLeverageModuleExecAfter;
        emit LeverageModuleUpdated(leverageModule);
    }

    /// @notice Cancel a pending leverage-module rotation.
    function cancelPendingLeverageModule() external onlyAdmin {
        delete pendingLeverageModule;
        delete pendingLeverageModuleExecAfter;
        emit LeverageModuleChangeCancelled();
    }

    /// @notice Set the dedicated liquidator wallet address.
    ///         Instant only if no liquidator is set yet (first-time setup).
    ///         Otherwise timelocked — use proposeAddress(3, addr) + executeAddress(3).
    function setLiquidator(address _liquidator) external onlyAdmin {
        if (_liquidator == address(0)) revert InvalidAddress();
        if (timelockDelay > 0 && liquidator != address(0)) revert TimelockNotReady();
        emit LiquidatorUpdated(liquidator, _liquidator);
        liquidator = _liquidator;
    }

    /// @notice Set the operation fee for relayed transactions (instant, no timelock)
    /// @param newFee Fee in USDC (6 decimals). E.g. 10000 = $0.01
    function setOperationFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_OPERATION_FEE) revert FeeTooHigh();
        operationFee = newFee;
        emit OperationFeeUpdated(newFee);
    }

    /// @notice Withdraw accumulated USDC operation fees (for relayer gas top-up).
    /// Callable by admin or relayer. USDC is sent to the caller.
    function withdrawOperationFees(uint256 amount) external {
        if (msg.sender != admin && msg.sender != relayer) revert NotAdmin();
        if (amount > operationFeePool) amount = operationFeePool;
        operationFeePool -= amount;
        IERC20(_asset()).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw accumulated CTF fee shares (for CLOB sale → relayer gas).
    /// Callable by admin or relayer.
    function withdrawFeeShares(uint256 tokenId, uint256 amount, address to) external {
        if (msg.sender != admin && msg.sender != relayer) revert NotAdmin();
        if (amount > feeSharesAccumulated[tokenId]) amount = feeSharesAccumulated[tokenId];
        feeSharesAccumulated[tokenId] -= amount;
        ICTF(ctf).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    /// @notice Sweep orphaned USDC from fee shares that were redeemed during market resolution.
    ///         When fee shares are still in the contract at redemption time, they get redeemed
    ///         with user collateral but no borrower can claim the pro-rata USDC. This moves
    ///         that orphaned USDC from unsettledRedemptions into operationFeePool.
    function sweepRedeemedFeeShares(uint256 tokenId) external {
        if (msg.sender != admin && msg.sender != relayer) revert NotAdmin();
        Redemption storage r = redeemedTokens[tokenId];
        if (!r.redeemed) revert TokenNotRedeemed();
        uint256 feeShares = feeSharesAccumulated[tokenId];
        if (feeShares == 0) return;

        uint256 orphaned = feeShares.mulDiv(r.usdcReceived, r.totalShares, Math.Rounding.Floor);
        if (orphaned > unsettledRedemptions) orphaned = unsettledRedemptions;
        unsettledRedemptions -= orphaned;
        operationFeePool += orphaned;
        feeSharesAccumulated[tokenId] = 0;
    }

    /// @notice Activate or increase the timelock delay (one-way ratchet).
    /// @dev Capped at MAX_TIMELOCK_DELAY (10 days) to prevent accidentally bricking governance
    ///      with an unreachable delay.
    function activateTimelock(uint256 delay) external onlyAdmin {
        if (delay < timelockDelay) revert TimelockCannotDecrease();
        if (delay > MAX_TIMELOCK_DELAY) revert TimelockExceedsMaximum();
        timelockDelay = delay;
        emit TimelockActivated(delay);
    }


    /*//////////////////////////////////////////////////////////////
                  ADMIN — TIMELOCKED (dangerous operations)
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a timelocked address change. kind: 0=oracle, 1=relayer, 2=upgrade, 3=liquidator
    function proposeAddress(uint8 kind, address addr) external onlyAdmin {
        if (addr == address(0)) revert InvalidAddress();
        uint256 execAfter = block.timestamp + timelockDelay;
        if (kind == 0) { pendingOracle = addr; pendingOracleExecAfter = execAfter; emit OracleChangeProposed(addr, execAfter); }
        else if (kind == 1) { pendingRelayer = addr; pendingRelayerExecAfter = execAfter; emit RelayerChangeProposed(addr, execAfter); }
        else if (kind == 2) { pendingUpgrade = addr; pendingUpgradeExecAfter = execAfter; emit UpgradeProposed(addr, execAfter); }
        else if (kind == 3) { pendingLiquidator = addr; pendingLiquidatorExecAfter = execAfter; emit LiquidatorChangeProposed(addr, execAfter); }
        else { revert InvalidAddress(); }
    }

    /// @notice Execute a timelocked address change. kind: 0=oracle, 1=relayer, 3=liquidator
    function executeAddress(uint8 kind) external onlyAdmin {
        if (kind == 0) {
            if (pendingOracle == address(0)) revert NoPendingChange();
            if (block.timestamp < pendingOracleExecAfter) revert TimelockNotReady();
            emit OracleUpdated(oracle, pendingOracle);
            oracle = pendingOracle;
            delete pendingOracle; delete pendingOracleExecAfter;
        } else if (kind == 1) {
            if (pendingRelayer == address(0)) revert NoPendingChange();
            if (block.timestamp < pendingRelayerExecAfter) revert TimelockNotReady();
            emit RelayerUpdated(relayer, pendingRelayer);
            relayer = pendingRelayer;
            delete pendingRelayer; delete pendingRelayerExecAfter;
        } else if (kind == 3) {
            if (pendingLiquidator == address(0)) revert NoPendingChange();
            if (block.timestamp < pendingLiquidatorExecAfter) revert TimelockNotReady();
            emit LiquidatorUpdated(liquidator, pendingLiquidator);
            liquidator = pendingLiquidator;
            delete pendingLiquidator; delete pendingLiquidatorExecAfter;
        } else {
            revert NoPendingChange();
        }
    }

    /// @notice Propose new risk model anchor points
    function proposeAnchors(
        uint256[NUM_ANCHORS] calldata prices,
        uint256[NUM_ANCHORS] calldata ltvs
    ) external onlyAdmin {
        for (uint256 i = 0; i < NUM_ANCHORS; i++) {
            if (ltvs[i] + PredmartPoolLib.LIQUIDATION_BUFFER > 1e18) revert InvalidAnchors();
            if (i > 0) {
                if (prices[i] <= prices[i - 1]) revert InvalidAnchors();
                if (ltvs[i] < ltvs[i - 1]) revert InvalidAnchors();
            }
        }
        pendingPriceAnchors = prices;
        pendingLtvAnchors = ltvs;
        pendingAnchorsExecAfter = block.timestamp + timelockDelay;
        emit AnchorsChangeProposed(pendingAnchorsExecAfter);
    }

    /// @notice Execute a pending anchors change
    function executeAnchors() external onlyAdmin {
        if (pendingAnchorsExecAfter == 0) revert NoPendingChange();
        if (block.timestamp < pendingAnchorsExecAfter) revert TimelockNotReady();
        priceAnchors = pendingPriceAnchors;
        ltvAnchors = pendingLtvAnchors;
        delete pendingAnchorsExecAfter;
        emit AnchorsUpdated();
    }

    /// @notice Cancel a pending timelocked change. kind: 0=oracle, 1=relayer, 2=upgrade, 3=liquidator, 4=anchors
    function cancelPending(uint8 kind) external onlyAdmin {
        if (kind == 0) { delete pendingOracle; delete pendingOracleExecAfter; emit OracleChangeCancelled(); }
        else if (kind == 1) { delete pendingRelayer; delete pendingRelayerExecAfter; }
        else if (kind == 2) { delete pendingUpgrade; delete pendingUpgradeExecAfter; emit UpgradeCancelled(); }
        else if (kind == 3) { delete pendingLiquidator; delete pendingLiquidatorExecAfter; emit LiquidatorChangeCancelled(); }
        else if (kind == 4) { delete pendingAnchorsExecAfter; emit AnchorsChangeCancelled(); }
    }

    /*//////////////////////////////////////////////////////////////
              MARKET RESOLUTION & SETTLEMENT (moved from main)
    //////////////////////////////////////////////////////////////*/

    // NOTE: These functions are called via delegatecall from the main contract's fallback().
    // They inline _accrueInterest, _toBorrowAssets, and _reduceBorrowTracking because
    // the extension cannot call the main contract's internal functions.

    /// @dev Inline interest accrual — must match PredmartLendingPool._accrueInterest() exactly.
    function _accrueInterestInline() internal {
        if (totalBorrowAssets == 0) {
            lastAccrualTimestamp = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 totalLiquidity = IERC20(_asset()).balanceOf(address(this)) + totalBorrowAssets + totalPendingCloses + totalPendingAdvances + totalPendingLiquidations;
        totalLiquidity = totalLiquidity > totalReserves ? totalLiquidity - totalReserves : 0;
        totalLiquidity = totalLiquidity > unsettledRedemptions ? totalLiquidity - unsettledRedemptions : 0;
        totalLiquidity = totalLiquidity > operationFeePool ? totalLiquidity - operationFeePool : 0;
        totalLiquidity = totalLiquidity > protocolFeePool ? totalLiquidity - protocolFeePool : 0;
        uint256 utilization = totalLiquidity == 0 ? 0 : totalBorrowAssets.mulDiv(1e18, totalLiquidity);

        (uint256 interest, uint256 reserveShare) = PredmartPoolLib.calcPendingInterest(
            totalBorrowAssets, elapsed, utilization
        );
        if (interest > 0) {
            totalBorrowAssets += interest;
            totalReserves += reserveShare;
            emit InterestAccrued(interest, reserveShare);
        }
        lastAccrualTimestamp = block.timestamp;
    }

    /// @dev Inline borrow shares → assets conversion.
    function _toBorrowAssetsInline(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(totalBorrowAssets + 1, totalBorrowShares + 1e6, Math.Rounding.Ceil);
    }

    /// @dev Inline reduce borrow tracking — must match PredmartLendingPool._reduceBorrowTracking().
    function _reduceBorrowTrackingInline(uint256 tokenId, uint256 assets, uint256 shares, uint256 principalReduction) internal {
        totalBorrowAssets = totalBorrowAssets > assets ? totalBorrowAssets - assets : 0;
        totalBorrowShares = totalBorrowShares > shares ? totalBorrowShares - shares : 0;
        if (totalBorrowAssets == 0 && totalBorrowShares > 0) totalBorrowShares = 0;
        if (totalBorrowShares == 0 && totalBorrowAssets > 0) totalBorrowAssets = 0;
        totalBorrowedPerToken[tokenId] = totalBorrowedPerToken[tokenId] > principalReduction
            ? totalBorrowedPerToken[tokenId] - principalReduction : 0;
    }

    /// @dev Inline borrow assets → shares conversion (must match PredmartLendingPool._toBorrowShares).
    function _toBorrowSharesInline(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalBorrowShares + 1e6, totalBorrowAssets + 1, rounding);
    }

    /// @dev Inline health factor calculation (must match PredmartLendingPool._getHealthFactor).
    function _getHealthFactorInline(uint256 collateralAmount, uint256 debt, uint256 price) internal view returns (uint256) {
        uint256 ltv = PredmartPoolLib.interpolate(priceAnchors, ltvAnchors, price);
        uint256 liqThreshold = ltv + PredmartPoolLib.LIQUIDATION_BUFFER;
        return PredmartPoolLib.calcHealthFactor(collateralAmount, debt, price, liqThreshold);
    }

    /// @dev Get the ERC-4626 underlying asset address via the ERC-7201 namespaced storage slot.
    function _asset() internal view returns (address) {
        // ERC4626Upgradeable stores the asset in namespaced storage.
        // Slot = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
        // But we can use a simpler approach: read it from the proxy's own context via the known getter.
        // Since we're in delegatecall, address(this) is the proxy, and we need the stored USDC address.
        // The ERC-4626 asset is stored in OZ namespaced storage — we hardcode the known USDC address.
        // This is safe because asset() is immutable after initialization.
        bytes32 slot = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
        address asset_;
        assembly { asset_ := sload(slot) }
        return asset_;
    }

    /// @notice Mark a Polymarket market as resolved. Permissionless.
    function resolveMarket(uint256 tokenId, PredmartOracle.ResolutionData calldata data) external {
        if (resolvedMarkets[tokenId].resolved) revert MarketAlreadyResolved();
        if (data.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();

        bool won = PredmartOracle.verifyResolution(data, oracle, address(this), MAX_RESOLUTION_AGE);
        resolvedMarkets[tokenId] = MarketResolution({ resolved: true, won: won });

        emit MarketResolvedEvent(tokenId, won);
    }

    /// @notice Close a position in a resolved market. Permissionless.
    function closeLostPosition(address borrower, uint256 tokenId) external {
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved) revert MarketNotResolved();

        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        if (resolution.won) revert UseRedemptionFlow();

        uint256 badDebt = pos.borrowShares > 0
            ? _toBorrowAssetsInline(pos.borrowShares)
            : 0;
        if (pos.borrowShares > 0) {
            _reduceBorrowTrackingInline(tokenId, badDebt, pos.borrowShares,
                pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : badDebt);
        }
        delete positions[borrower][tokenId];
        if (badDebt > 0) emit BadDebtAbsorbed(borrower, tokenId, badDebt);
        emit PositionClosed(borrower, tokenId, badDebt);
    }

    /// @notice Redeem winning CTF shares for USDC. Permissionless.
    function redeemWonCollateral(uint256 tokenId, bytes32 conditionId, uint256 indexSet) external {
        _redeemWonCollateral(tokenId, conditionId, indexSet, false);
    }

    /// @notice Redeem winning neg_risk CTF shares via NegRiskAdapter
    /// @param outcomeIndex 0 for YES tokens, 1 for NO tokens
    function redeemWonCollateralNegRisk(uint256 tokenId, bytes32 conditionId, uint256 outcomeIndex) external {
        _redeemWonCollateral(tokenId, conditionId, outcomeIndex, true);
    }

    function _redeemWonCollateral(uint256 tokenId, bytes32 conditionId, uint256 indexSet, bool negRisk) internal {
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved || !resolution.won) revert MarketNotResolved();
        if (redeemedTokens[tokenId].redeemed) revert AlreadyRedeemed();

        address asset_ = _asset();
        uint256 sharesBefore = ICTF(ctf).balanceOf(address(this), tokenId);
        uint256 usdcBefore = IERC20(asset_).balanceOf(address(this));

        if (negRisk) {
            // NegRisk: approve adapter, then call adapter.redeemPositions
            // amounts[] has 2 elements: [yes_amount, no_amount]. Only the winning side is non-zero.
            if (negRiskAdapter == address(0)) revert InvalidAddress();
            if (!ICTF(ctf).isApprovedForAll(address(this), negRiskAdapter)) {
                ICTF(ctf).setApprovalForAll(negRiskAdapter, true);
            }
            uint256[] memory amounts = new uint256[](2);
            amounts[indexSet] = sharesBefore; // indexSet = 0 for YES, 1 for NO
            INegRiskAdapter(negRiskAdapter).redeemPositions(conditionId, amounts);
        } else {
            // Standard: call CTF.redeemPositions directly
            uint256[] memory indexSets = new uint256[](1);
            indexSets[0] = indexSet;
            ICTF(ctf).redeemPositions(asset_, bytes32(0), conditionId, indexSets);
        }

        uint256 sharesAfter = ICTF(ctf).balanceOf(address(this), tokenId);
        uint256 usdcAfter = IERC20(asset_).balanceOf(address(this));

        if (sharesAfter >= sharesBefore) revert RedemptionFailed();

        uint256 sharesRedeemed = sharesBefore - sharesAfter;
        uint256 usdcReceived = usdcAfter - usdcBefore;
        redeemedTokens[tokenId] = Redemption(true, sharesRedeemed, usdcReceived);
        unsettledRedemptions += usdcReceived;

        emit CollateralRedeemed(tokenId, sharesRedeemed, usdcReceived);
    }

    /// @notice Settle a borrower's position after CTF redemption. Permissionless.
    /// @dev Surplus is sent to position.recipient (set at borrow / leverage-open time, =
    ///      user's Safe in V2-native flows). The recipient is signed by the user; settle
    ///      remains permissionless because anyone calling settleRedemption can only
    ///      route to the address the user pre-authorized.
    function settleRedemption(address borrower, uint256 tokenId) external {
        Redemption storage redemption = redeemedTokens[tokenId];
        if (!redemption.redeemed) revert TokenNotRedeemed();

        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        address recipient = pos.recipient;
        if (recipient == address(0)) revert InvalidAddress();

        uint256 proceeds = pos.collateralAmount.mulDiv(redemption.usdcReceived, redemption.totalShares, Math.Rounding.Floor);
        uint256 debt = pos.borrowShares > 0
            ? _toBorrowAssetsInline(pos.borrowShares)
            : 0;

        if (pos.borrowShares > 0) {
            _reduceBorrowTrackingInline(tokenId, debt, pos.borrowShares,
                pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : debt);
        }

        unsettledRedemptions = unsettledRedemptions > proceeds ? unsettledRedemptions - proceeds : 0;

        uint256 surplus = proceeds > debt ? proceeds - debt : 0;

        // Profit fee: 10% of profit (surplus above initial equity)
        // Legacy positions (initialEquity == 0) are exempt
        uint256 initialEquity = pos.initialEquity;
        if (initialEquity > 0 && surplus > initialEquity) {
            uint256 profit = surplus - initialEquity;
            uint256 poolFee = profit.mulDiv(PredmartPoolLib.PROFIT_FEE_POOL, 1e18);
            uint256 protocolFee = profit.mulDiv(PredmartPoolLib.PROFIT_FEE_PROTOCOL, 1e18);
            surplus -= (poolFee + protocolFee);
            protocolFeePool += protocolFee;
            emit ProfitFeeCollected(borrower, tokenId, poolFee, protocolFee);
        }

        if (debt > proceeds) emit BadDebtAbsorbed(borrower, tokenId, debt - proceeds);
        delete positions[borrower][tokenId];

        if (surplus > 0) {
            IERC20(_asset()).safeTransfer(recipient, surplus);
        }

        emit RedemptionSettled(borrower, tokenId, debt, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice v2 Liquidate an unhealthy position — seize ALL collateral, sell later.
    /// @dev Seize-first model: liquidator receives all shares, sells on CLOB,
    ///      then calls settleLiquidation() with proceeds. No upfront USDC required.
    ///      Only callable by the dedicated liquidator wallet.
    ///      Intentionally lacks whenNotPaused: during emergencies, liquidation must continue
    ///      to protect lenders from accumulating bad debt.
    function liquidate(
        address borrower,
        uint256 tokenId,
        PredmartOracle.PriceData calldata priceData
    ) external {
        if (msg.sender != liquidator) revert NotLiquidator();
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (resolution.resolved && !resolution.won) revert MarketResolved();
        if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), 60 seconds);

        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        uint256 debt = _toBorrowAssetsInline(pos.borrowShares);
        uint256 healthFactor = _getHealthFactorInline(pos.collateralAmount, debt, price);
        if (healthFactor >= 1e18) revert PositionHealthy();

        uint256 collateral = pos.collateralAmount;

        // Record pending liquidation (settled after CLOB sale)
        pendingLiquidations[borrower][tokenId] = PendingLiquidation({
            liquidator: msg.sender,
            debt: debt,
            collateral: collateral,
            timestamp: block.timestamp
        });
        totalPendingLiquidations += debt;

        // Zero out position — burn all borrow shares, clear all tracking
        _reduceBorrowTrackingInline(tokenId, debt, pos.borrowShares,
            pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : debt);
        delete positions[borrower][tokenId];

        // Transfer ALL shares to liquidator
        ICTF(ctf).safeTransferFrom(address(this), msg.sender, tokenId, collateral, "");

        emit Liquidated(msg.sender, borrower, tokenId, collateral, debt);
    }

    /// @notice Settle a pending liquidation after the liquidator sold shares on CLOB.
    /// @param borrower The liquidated borrower
    /// @param tokenId The token ID of the liquidated position
    /// @param saleProceeds Total USDC received from CLOB sale
    function settleLiquidation(
        address borrower,
        uint256 tokenId,
        uint256 saleProceeds
    ) external {
        PendingLiquidation memory pending = pendingLiquidations[borrower][tokenId];
        if (pending.liquidator == address(0)) revert NoPendingLiquidation();
        if (msg.sender != pending.liquidator) revert NotLiquidator();

        uint256 debt = pending.debt;

        // Clean up pending state BEFORE external calls (CEI pattern)
        totalPendingLiquidations = totalPendingLiquidations > debt
            ? totalPendingLiquidations - debt : 0;
        delete pendingLiquidations[borrower][tokenId];

        // Pull ALL proceeds from caller
        if (saleProceeds > 0) {
            IERC20(_asset()).safeTransferFrom(msg.sender, address(this), saleProceeds);
        }

        if (saleProceeds >= debt) {
            // Solvent: repay debt + distribute
            uint256 liquidatorFee = debt.mulDiv(PredmartPoolLib.LIQUIDATOR_FEE, 1e18);
            uint256 surplus = saleProceeds - debt;

            // Fee to liquidator (msg.sender == pending.liquidator, verified above).
            // Liquidator fee is a priority payment by design (keeper-priority model):
            // keeper compensation is guaranteed regardless of surplus depth, ensuring
            // timely liquidations even when proceeds barely cover debt.
            if (liquidatorFee > 0) {
                IERC20(_asset()).safeTransfer(msg.sender, liquidatorFee);
            }

            // When `liquidatorFee > surplus`, the pool nets less than `debt` after
            // paying the keeper. Emit BadDebtAbsorbed for the shortfall so monitoring
            // can categorize the cost consistently with the insolvent path — without
            // this, the bleed is invisible (no event differentiates it from a clean
            // settlement) and lenders cannot reconcile actual pool deltas.
            if (liquidatorFee > surplus) {
                emit BadDebtAbsorbed(borrower, tokenId, liquidatorFee - surplus);
            }

            // Remaining surplus (if any beyond the keeper fee) stays in contract
            // (increases totalAssets for lenders). Borrower gets $0.

            emit LiquidationSettled(borrower, tokenId, debt, liquidatorFee, surplus);
        } else {
            // Insolvent: bad debt socialized to lenders
            uint256 badDebt = debt - saleProceeds;
            emit BadDebtAbsorbed(borrower, tokenId, badDebt);
        }
    }

    /// @notice Expire a pending liquidation that wasn't settled within 48 hours.
    ///         Permissionless after 48 hours; `admin` and `liquidator` may expire immediately.
    /// @dev Full debt amount becomes bad debt, socialized to lenders. The position's debt
    ///      was already zeroed in liquidate(), so expiring just cleans up the slot — no
    ///      money moves. Granting the liquidator instant-expire lets the bot mark a CLOB
    ///      sale as conclusively failed without holding the slot open for 48 hours.
    function expirePendingLiquidation(address borrower, uint256 tokenId) external {
        PendingLiquidation memory pending = pendingLiquidations[borrower][tokenId];
        if (pending.liquidator == address(0)) revert NoPendingLiquidation();
        if (msg.sender != admin && msg.sender != liquidator) {
            if (block.timestamp < pending.timestamp + 48 hours) revert TooEarly();
        }

        totalPendingLiquidations = totalPendingLiquidations > pending.debt
            ? totalPendingLiquidations - pending.debt : 0;
        delete pendingLiquidations[borrower][tokenId];

        emit BadDebtAbsorbed(borrower, tokenId, pending.debt);
    }

    /*//////////////////////////////////////////////////////////////
                   POOL-FUNDED FLASH CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Close an entire position. Pool absorbs the debt gap temporarily.
    /// @dev Moved from main contract to extension for EIP-170 size limit.
    ///      Shares go to msg.sender (relayer) for CLOB sale. Relayer calls settleClose() after.
    function initiateClose(
        CloseAuth calldata auth,
        bytes calldata authSignature,
        PredmartOracle.PriceData calldata priceData
    ) external {
        if (paused) revert ProtocolPaused();
        if (auth.allowedTo == address(0)) revert InvalidAddress();
        if (msg.sender != relayer) revert NotRelayer();
        if (resolvedMarkets[auth.tokenId].resolved) revert MarketResolved();
        if (block.timestamp > auth.deadline) revert IntentExpired();
        if (auth.nonce != closeNonces[auth.borrower][auth.tokenId]) revert InvalidNonce();

        // Verify EIP-712 signature via SignatureChecker so contract-account borrowers (Safes)
        // can sign CloseAuth via EIP-1271.
        bytes32 structHash = keccak256(abi.encode(
            CLOSE_AUTH_TYPEHASH, auth.borrower, auth.allowedTo, auth.tokenId, auth.nonce, auth.deadline
        ));
        bytes32 digest = _hashTypedDataV4Ext(structHash);
        if (!SignatureChecker.isValidSignatureNow(auth.borrower, digest, authSignature)) {
            revert InvalidIntentSignature();
        }

        // Consume nonce
        closeNonces[auth.borrower][auth.tokenId]++;

        // Block double close
        if (pendingCloses[auth.borrower][auth.tokenId].deadline != 0) revert PositionHasPendingClose();

        _accrueInterestInline();

        Position storage pos = positions[auth.borrower][auth.tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();
        if (pos.borrowShares == 0) revert NoPosition();

        uint256 collateralAmount = pos.collateralAmount;

        // Verify price and health
        if (priceData.tokenId != auth.tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
        uint256 debt = _toBorrowAssetsInline(pos.borrowShares);
        if (_getHealthFactorInline(collateralAmount, debt, price) < 1e18) revert PositionUnhealthy();

        // Zero the borrow
        uint256 principal = pos.borrowedPrincipal > 0 ? pos.borrowedPrincipal : debt;
        _reduceBorrowTrackingInline(auth.tokenId, debt, pos.borrowShares, principal);
        pos.borrowShares = 0;
        pos.borrowedPrincipal = 0;

        // Record pending close
        pendingCloses[auth.borrower][auth.tokenId] = PendingClose({
            surplusRecipient: auth.allowedTo,
            debtAmount: debt,
            collateralAmount: collateralAmount,
            deadline: block.timestamp + CLOSE_TIMEOUT,
            initialEquity: pos.initialEquity
        });
        totalPendingCloses += debt;

        // Withdraw all collateral to relayer for CLOB sale
        pos.collateralAmount = 0;
        delete positions[auth.borrower][auth.tokenId];
        ICTF(ctf).safeTransferFrom(address(this), msg.sender, auth.tokenId, collateralAmount, "");

        emit PositionCloseInitiated(auth.borrower, auth.tokenId, debt, collateralAmount);
    }

    /// @notice Settle a pending flash close after the relayer sold shares on CLOB.
    /// @dev Only callable by relayer. Two-token settlement (V2-native):
    ///      - relayer pays debt + protocol-tied fees in USDC.e (lender-side accounting)
    ///      - relayer pays user surplus in pUSD (so user keeps Polymarket-ready currency)
    ///      Caller pre-computes the split off-chain; this function verifies it matches the
    ///      contract's own debt/fee/surplus math. Mismatch reverts.
    /// @dev Bad debt scenario: relayer sets surplusPusd = 0 and debtAndFeeUsdce equal to all
    ///      proceeds (relayer unwrapped everything, pool absorbs the shortfall).
    /// @param borrower The position owner
    /// @param tokenId The token ID of the closed position
    /// @param debtAndFeeUsdce Amount of USDC.e the relayer is delivering (covers repaid debt + total profit fee)
    /// @param surplusPusd Amount of pUSD the relayer is delivering (= user's net surplus, sent to position's recipient)
    function settleClose(
        address borrower,
        uint256 tokenId,
        uint256 debtAndFeeUsdce,
        uint256 surplusPusd
    ) external {
        if (msg.sender != relayer) revert NotRelayer();

        PendingClose storage pending = pendingCloses[borrower][tokenId];
        if (pending.deadline == 0) revert NoPendingClose();

        // ── Checks ──
        uint256 debtAmount = pending.debtAmount;
        address surplusRecipient = pending.surplusRecipient;
        uint256 initialEquity = pending.initialEquity;
        uint256 saleProceeds = debtAndFeeUsdce + surplusPusd;

        uint256 surplus = saleProceeds > debtAmount ? saleProceeds - debtAmount : 0;
        uint256 badDebt = debtAmount > saleProceeds ? debtAmount - saleProceeds : 0;
        uint256 repaid = saleProceeds > debtAmount ? debtAmount : saleProceeds;

        // Profit fee: 10% of profit (surplus above initial equity)
        // 7% stays in pool (increases lender yield), 3% → protocol fee pool
        // Legacy positions (initialEquity == 0) are exempt
        uint256 expectedFee = 0;
        if (initialEquity > 0 && surplus > initialEquity) {
            uint256 profit = surplus - initialEquity;
            uint256 poolFee = profit.mulDiv(PredmartPoolLib.PROFIT_FEE_POOL, 1e18);
            uint256 protocolFee = profit.mulDiv(PredmartPoolLib.PROFIT_FEE_PROTOCOL, 1e18);
            expectedFee = poolFee + protocolFee;
            surplus -= expectedFee;
            protocolFeePool += protocolFee;
            emit ProfitFeeCollected(borrower, tokenId, poolFee, protocolFee);
        }

        // Verify relayer's split matches contract's math:
        //   USDC.e portion = repaid (debt or partial-debt) + expectedFee
        //   pUSD portion   = surplus (after fee deduction)
        // If split is wrong (relayer cheated or miscomputed), revert — pool side is non-negotiable.
        if (debtAndFeeUsdce != repaid + expectedFee) revert SettleAmountMismatch();
        if (surplusPusd != surplus) revert SettleAmountMismatch();

        // ── Effects ──
        totalPendingCloses = totalPendingCloses > debtAmount ? totalPendingCloses - debtAmount : 0;
        delete pendingCloses[borrower][tokenId];

        emit CloseSettled(borrower, tokenId, repaid, badDebt, surplus);
        if (badDebt > 0) {
            emit BadDebtAbsorbed(borrower, tokenId, badDebt);
        }

        // ── Interactions ──
        if (debtAndFeeUsdce > 0) {
            IERC20(_asset()).safeTransferFrom(msg.sender, address(this), debtAndFeeUsdce);
        }
        if (surplusPusd > 0) {
            // Pull pUSD from relayer and forward to user's Safe in one trustless step.
            // Relayer must have pUSD → LendingPool approval (set during V2 onboarding).
            IERC20(PUSD).safeTransferFrom(msg.sender, surplusRecipient, surplusPusd);
        }
    }

    /// @notice Expire a timed-out pending close. Permissionless after the deadline;
    ///         `admin` and `relayer` may expire immediately.
    /// @dev Full debt amount becomes bad debt, socialized to lenders. The pool's debt
    ///      was already zeroed in initiateClose, so expiring just cleans up the slot —
    ///      no money moves. Granting the relayer instant-expire lets the backend close
    ///      out the slot as soon as a CLOB sale is conclusively confirmed failed,
    ///      instead of waiting the full 48-hour deadline.
    /// @param borrower The position owner
    /// @param tokenId The token ID of the closed position
    function expirePendingClose(address borrower, uint256 tokenId) external {
        PendingClose storage pending = pendingCloses[borrower][tokenId];
        if (pending.deadline == 0) revert NoPendingClose();
        if (msg.sender != admin && msg.sender != relayer) {
            if (block.timestamp < pending.deadline) revert CloseNotExpired();
        }

        uint256 badDebt = pending.debtAmount;

        // Update accounting
        totalPendingCloses = totalPendingCloses > badDebt ? totalPendingCloses - badDebt : 0;

        // Clean up
        delete pendingCloses[borrower][tokenId];

        emit CloseExpired(borrower, tokenId, badDebt);
        emit BadDebtAbsorbed(borrower, tokenId, badDebt);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — ADVANCE RECOVERY
    //////////////////////////////////////////////////////////////*/

    event AdvanceExpired(bytes32 indexed authHash, uint256 amount);

    /// @notice Expire a stuck pending advance. Permissionless after 48 hours;
    ///         `admin` and `relayer` may expire immediately.
    /// @dev When the relayer received an advance but never called leverageDeposit, the
    ///      USDC sits in the relayer wallet. The relayer's auto-recovery (Phase A) returns
    ///      that USDC to the pool via plain ERC-20 transfer, but `pendingAdvances` and
    ///      `totalPendingAdvances` are not cleared by an ERC-20 transfer. Until cleared,
    ///      `totalAssets()` over-reports the pool by the gross advance amount, leading to
    ///      a temporary pUSDC inflation visible to lenders. Granting the relayer instant-
    ///      expire lets the backend hourly sweep clear Phase A advances within minutes
    ///      instead of waiting 48 hours.
    ///
    ///      The 48-hour permissionless path is preserved as a backstop: if the relayer is
    ///      down or compromised, anyone can clean up after the timer.
    function expireAdvance(bytes32 authHash) external {
        uint256 amount = pendingAdvances[authHash];
        if (amount == 0) revert NoPendingAdvance();
        if (msg.sender != admin && msg.sender != relayer) {
            if (block.timestamp < pendingAdvanceTimestamps[authHash] + 48 hours) revert TooEarly();
        }
        pendingAdvances[authHash] = 0;
        totalPendingAdvances -= amount;
        delete pendingAdvanceTimestamps[authHash];
        emit AdvanceExpired(authHash, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — RESERVES (moved from main for EIP-170)
    //////////////////////////////////////////////////////////////*/

    event ReservesWithdrawn(address indexed to, uint256 amount);

    /// @notice Withdraw accumulated protocol fees (3% of profit fees)
    function withdrawProtocolFees(uint256 amount) external onlyAdmin {
        if (amount > protocolFeePool) amount = protocolFeePool;
        protocolFeePool -= amount;
        IERC20(_asset()).safeTransfer(admin, amount);
    }

    /// @notice Withdraw accumulated protocol reserves
    function withdrawReserves(uint256 amount) external onlyAdmin {
        _accrueInterestInline();
        if (amount > totalReserves) amount = totalReserves;
        totalReserves -= amount;
        IERC20(_asset()).safeTransfer(admin, amount);
        emit ReservesWithdrawn(admin, amount);
    }

    // pullUsdcForLeverage moved to PredmartBorrowExtension. Reachable via selector-routed fallback.

    /// @dev CloseAuth struct used by initiateClose (still in this extension).
    struct CloseAuth {
        address borrower;
        address allowedTo;
        uint256 tokenId;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev Compute EIP-712 typed data hash matching the main contract's _hashTypedDataV4.
    ///      EIP712Upgradeable stores string name/version (not hashes) — we hardcode the hashes
    ///      since they're set once during initializeV3 and never change.
    function _hashTypedDataV4Ext(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Predmart Lending Pool"),
            keccak256("0.8.0"),
            block.chainid,
            address(this)
        ));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @notice Permissionless interest accrual trigger. Called via fallback → delegatecall.
    function accrueInterest() external {
        _accrueInterestInline();
    }

    /*//////////////////////////////////////////////////////////////
            DIRECT COLLATERAL DEPOSIT (moved from main — size)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit CTF shares as collateral directly from `msg.sender` (no Safe proxy).
    /// @dev Users with Polymarket proxy Safes should use `depositCollateralFrom` with an EIP-712 signature.
    ///      This path exists for users holding shares in their EOA.
    /// @notice Deposit ERC-1155 collateral on behalf of `borrower`. The shares
    ///         are pulled from `msg.sender` (the funds source) and credited to
    ///         `positions[borrower][tokenId]` (the position key). Separating
    ///         the two lets a Polymarket Safe deposit shares while the position
    ///         remains keyed to the user's EOA — required for V2-native flows
    ///         where pUSD/CTF balances live on the Safe but identity is the EOA.
    /// @dev    Caller (msg.sender) must hold the shares AND have setApprovalForAll
    ///         granted to this pool. There is no signature check on `borrower`:
    ///         depositing collateral on someone else's position can only ADD
    ///         value to it (collateral and initialEquity both grow), so it is
    ///         safe to permit unsolicited credits — same trust model as paying
    ///         off someone else's loan in repay().
    function depositCollateral(
        address borrower,
        uint256 tokenId,
        uint256 amount,
        PredmartOracle.PriceData calldata priceData
    ) external {
        if (paused) revert ProtocolPaused();
        // Reject no-op calls at the contract layer. Pre-V19 a zero-amount
        // call succeeded silently and emitted a CollateralDeposited event,
        // letting a griefer flood the indexer / DB with noise rows for the
        // cost of one tx of gas. Backend rate limits aren't real security
        // (see internal feedback) — close the vector at the source.
        if (amount == 0) revert InvalidAmount();

        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();
        if (pendingCloses[borrower][tokenId].deadline != 0) revert PositionHasPendingClose();

        ICTF(ctf).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        positions[borrower][tokenId].collateralAmount += amount;

        if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
        positions[borrower][tokenId].initialEquity += amount * price / 1e18;

        emit CollateralDeposited(borrower, tokenId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                   REPAY (moved from main — size)
    //////////////////////////////////////////////////////////////*/

    /// @notice Repay USDC debt for a position. Called via fallback → delegatecall from proxy.
    /// @dev Reentrancy protected by the proxy fallback's ERC-7201 guard.
    /// @notice Repay debt on `borrower`'s position. USDC.e is pulled from
    ///         msg.sender (the funds source); the debt is reduced on
    ///         positions[borrower][tokenId] (the position key). V2-native:
    ///         a Polymarket Safe pays USDC.e on behalf of the EOA-keyed
    ///         position. Permitting third-party repay is safe — paying down
    ///         someone else's debt only IMPROVES their health factor.
    function repay(address borrower, uint256 tokenId, uint256 amount) external {
        // Reject no-op calls so a spammer can't bloat the indexer / DB with
        // zero-amount Repaid events. Symmetric with depositCollateral.
        if (amount == 0) revert InvalidAmount();
        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.borrowShares == 0) revert NoPosition();

        uint256 currentDebt = _toBorrowAssetsInline(pos.borrowShares);
        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        uint256 sharesToBurn = (repayAmount == currentDebt)
            ? pos.borrowShares
            : _toBorrowSharesInline(repayAmount, Math.Rounding.Floor);

        uint256 pr = pos.borrowedPrincipal == 0 ? repayAmount
            : sharesToBurn >= pos.borrowShares ? pos.borrowedPrincipal
            : pos.borrowedPrincipal.mulDiv(sharesToBurn, pos.borrowShares, Math.Rounding.Floor);
        pos.borrowedPrincipal = pos.borrowedPrincipal > pr ? pos.borrowedPrincipal - pr : 0;

        IERC20(_asset()).safeTransferFrom(msg.sender, address(this), repayAmount);

        pos.borrowShares -= sharesToBurn;
        _reduceBorrowTrackingInline(tokenId, repayAmount, sharesToBurn, pr);

        emit Repaid(borrower, tokenId, repayAmount);
    }
}
