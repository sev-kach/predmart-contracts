// SPDX-License-Identifier: MIT
// contracts/src/PredmartPoolExtension.sol
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { ICTF } from "./interfaces/ICTF.sol";
import {
    Position, MarketResolution, Redemption, PendingClose,
    NotAdmin, InvalidAddress, NoPosition, TimelockNotReady, NoPendingChange, NotRelayer,
    BadDebtAbsorbed, InterestAccrued, OperationFeeCollected, OperationFeeUpdated
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

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAnchors();
    error TimelockCannotDecrease();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error TokenNotRedeemed();
    error AlreadyRedeemed();
    error RedemptionFailed();
    error UseRedemptionFlow();
    error NoPendingClose();
    error InsufficientLiquidity();
    error NoPendingAdvance();
    error CloseNotExpired();
    error FeeTooHigh();
    error MarketResolved();
    error AdvanceTooSmall();

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

    // v1.2.0 — Pool-funded flash close (must match PredmartLendingPool)
    mapping(address => uint256) public closeNonces;
    uint256 public totalPendingCloses;
    mapping(address => mapping(uint256 => PendingClose)) public pendingCloses;

    // v1.3.0 — Operation fee (must match PredmartLendingPool storage layout)
    uint256 public operationFee;
    uint256 public operationFeePool;
    mapping(uint256 => uint256) public feeSharesAccumulated;

    // v1.5.0 — Single-step leverage (must match PredmartLendingPool storage layout)
    mapping(bytes32 => uint256) public pendingAdvances;
    uint256 public totalPendingAdvances;
    uint256 private _advanceOffset;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // Errors for pullUsdcForLeverage (defined in main contract, redeclared here for the extension)
    error BorrowTooSmall();
    error IntentExpired();
    error InvalidIntentSignature();
    error InvalidNonce();
    error ExceedsBorrowBudget();

    /*//////////////////////////////////////////////////////////////
                      ADMIN — INSTANT (safe operations)
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose admin transfer. Takes effect after timelock delay.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        if (timelockDelay == 0) {
            admin = newAdmin; // Bootstrap: instant transfer when no timelock
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

    /// @notice Pause or unpause the protocol
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /// @notice Set per-token borrow cap as basis points of totalAssets
    function setPoolCapBps(uint256 newCapBps) external onlyAdmin {
        poolCapBps = newCapBps;
        emit PoolCapUpdated(newCapBps);
    }

    /// @notice Set the operation fee for relayed transactions (instant, no timelock)
    /// @param newFee Fee in USDC (6 decimals). E.g. 30000 = $0.03
    function setOperationFee(uint256 newFee) external onlyAdmin {
        if (newFee > MAX_OPERATION_FEE) revert FeeTooHigh();
        operationFee = newFee;
        emit OperationFeeUpdated(newFee);
    }

    /// @notice Withdraw accumulated USDC operation fees (for relayer gas top-up)
    function withdrawOperationFees(uint256 amount) external onlyAdmin {
        if (amount > operationFeePool) amount = operationFeePool;
        operationFeePool -= amount;
        IERC20(_asset()).safeTransfer(admin, amount);
    }

    /// @notice Withdraw accumulated CTF fee shares (for CLOB sale → relayer gas)
    function withdrawFeeShares(uint256 tokenId, uint256 amount, address to) external onlyAdmin {
        if (amount > feeSharesAccumulated[tokenId]) amount = feeSharesAccumulated[tokenId];
        feeSharesAccumulated[tokenId] -= amount;
        ICTF(ctf).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    /// @notice Sweep orphaned USDC from fee shares that were redeemed during market resolution.
    ///         When fee shares are still in the contract at redemption time, they get redeemed
    ///         with user collateral but no borrower can claim the pro-rata USDC. This moves
    ///         that orphaned USDC from unsettledRedemptions into operationFeePool.
    function sweepRedeemedFeeShares(uint256 tokenId) external onlyAdmin {
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

    /// @notice Activate or increase the timelock delay (one-way ratchet)
    function activateTimelock(uint256 delay) external onlyAdmin {
        if (delay < timelockDelay) revert TimelockCannotDecrease();
        timelockDelay = delay;
        emit TimelockActivated(delay);
    }


    /*//////////////////////////////////////////////////////////////
                  ADMIN — TIMELOCKED (dangerous operations)
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a timelocked address change. kind: 0=oracle, 1=relayer, 2=upgrade
    function proposeAddress(uint8 kind, address addr) external onlyAdmin {
        if (addr == address(0)) revert InvalidAddress();
        uint256 execAfter = block.timestamp + timelockDelay;
        if (kind == 0) { pendingOracle = addr; pendingOracleExecAfter = execAfter; emit OracleChangeProposed(addr, execAfter); }
        else if (kind == 1) { pendingRelayer = addr; pendingRelayerExecAfter = execAfter; emit RelayerChangeProposed(addr, execAfter); }
        else { pendingUpgrade = addr; pendingUpgradeExecAfter = execAfter; emit UpgradeProposed(addr, execAfter); }
    }

    /// @notice Execute a timelocked address change. kind: 0=oracle, 1=relayer
    function executeAddress(uint8 kind) external onlyAdmin {
        if (kind == 0) {
            if (pendingOracle == address(0)) revert NoPendingChange();
            if (block.timestamp < pendingOracleExecAfter) revert TimelockNotReady();
            emit OracleUpdated(oracle, pendingOracle);
            oracle = pendingOracle;
            delete pendingOracle; delete pendingOracleExecAfter;
        } else {
            if (pendingRelayer == address(0)) revert NoPendingChange();
            if (block.timestamp < pendingRelayerExecAfter) revert TimelockNotReady();
            emit RelayerUpdated(relayer, pendingRelayer);
            relayer = pendingRelayer;
            delete pendingRelayer; delete pendingRelayerExecAfter;
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

    /// @notice Cancel a pending timelocked change. kind: 0=oracle, 1=relayer, 2=upgrade, 3=anchors
    function cancelPending(uint8 kind) external onlyAdmin {
        if (kind == 0) { delete pendingOracle; delete pendingOracleExecAfter; emit OracleChangeCancelled(); }
        else if (kind == 1) { delete pendingRelayer; delete pendingRelayerExecAfter; }
        else if (kind == 2) { delete pendingUpgrade; delete pendingUpgradeExecAfter; emit UpgradeCancelled(); }
        else { delete pendingAnchorsExecAfter; emit AnchorsChangeCancelled(); }
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

        uint256 totalLiquidity = IERC20(_asset()).balanceOf(address(this)) + totalBorrowAssets + totalPendingCloses + totalPendingAdvances;
        totalLiquidity = totalLiquidity > totalReserves ? totalLiquidity - totalReserves : 0;
        totalLiquidity = totalLiquidity > unsettledRedemptions ? totalLiquidity - unsettledRedemptions : 0;
        totalLiquidity = totalLiquidity > operationFeePool ? totalLiquidity - operationFeePool : 0;
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
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved || !resolution.won) revert MarketNotResolved();
        if (redeemedTokens[tokenId].redeemed) revert AlreadyRedeemed();

        address asset_ = _asset();
        uint256 sharesBefore = ICTF(ctf).balanceOf(address(this), tokenId);
        uint256 usdcBefore = IERC20(asset_).balanceOf(address(this));

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = indexSet;
        ICTF(ctf).redeemPositions(asset_, bytes32(0), conditionId, indexSets);

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
    function settleRedemption(address borrower, uint256 tokenId) external {
        Redemption storage redemption = redeemedTokens[tokenId];
        if (!redemption.redeemed) revert TokenNotRedeemed();

        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

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
        if (debt > proceeds) emit BadDebtAbsorbed(borrower, tokenId, debt - proceeds);
        delete positions[borrower][tokenId];

        if (surplus > 0) {
            IERC20(_asset()).safeTransfer(borrower, surplus);
        }

        emit RedemptionSettled(borrower, tokenId, debt, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                   POOL-FUNDED FLASH CLOSE — SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle a pending flash close after the relayer sold shares on CLOB.
    /// @dev Only callable by relayer. The relayer is trusted to report honest saleProceeds —
    ///      under-reporting would steal user surplus. Relayer rotation is timelocked (6h).
    ///      Follows checks-effects-interactions: state changes before external transfers.
    /// @param borrower The position owner
    /// @param tokenId The token ID of the closed position
    /// @param saleProceeds USDC received from CLOB sale (6 decimals)
    function settleClose(address borrower, uint256 tokenId, uint256 saleProceeds) external {
        if (msg.sender != relayer) revert NotRelayer();

        PendingClose storage pending = pendingCloses[borrower][tokenId];
        if (pending.deadline == 0) revert NoPendingClose();

        // ── Checks ──
        uint256 debtAmount = pending.debtAmount;
        address surplusRecipient = pending.surplusRecipient;

        // Calculate surplus/badDebt BEFORE fee deduction (lender protection takes priority)
        uint256 surplus = saleProceeds > debtAmount ? saleProceeds - debtAmount : 0;
        uint256 badDebt = debtAmount > saleProceeds ? debtAmount - saleProceeds : 0;
        uint256 repaid = saleProceeds > debtAmount ? debtAmount : saleProceeds;

        // Operation fee is deducted from surplus only (user pays, not lenders)
        // If surplus < fee, fee is waived to protect lenders from bad debt
        uint256 feeCollected = 0;
        if (operationFee > 0 && surplus >= operationFee) {
            feeCollected = operationFee;
            operationFeePool += feeCollected;
            surplus -= feeCollected;
            emit OperationFeeCollected(borrower, feeCollected);
        }

        // ── Effects ──
        totalPendingCloses = totalPendingCloses > debtAmount ? totalPendingCloses - debtAmount : 0;
        delete pendingCloses[borrower][tokenId];

        emit CloseSettled(borrower, tokenId, repaid, badDebt, surplus);
        if (badDebt > 0) {
            emit BadDebtAbsorbed(borrower, tokenId, badDebt);
        }

        // ── Interactions ──
        address asset_ = _asset();
        if (saleProceeds > 0) {
            IERC20(asset_).safeTransferFrom(msg.sender, address(this), saleProceeds);
        }
        if (surplus > 0) {
            IERC20(asset_).safeTransfer(surplusRecipient, surplus);
        }
    }

    /// @notice Expire a timed-out pending close. Permissionless — anyone can call after deadline.
    /// @dev Full debt amount becomes bad debt, socialized to lenders.
    /// @param borrower The position owner
    /// @param tokenId The token ID of the closed position
    function expirePendingClose(address borrower, uint256 tokenId) external {
        PendingClose storage pending = pendingCloses[borrower][tokenId];
        if (pending.deadline == 0) revert NoPendingClose();
        if (block.timestamp < pending.deadline) revert CloseNotExpired();

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

    /// @notice Clear a stuck pending advance after admin recovery of USDC from relayer.
    /// @dev Admin-only. Use when the relayer received an advance but never called leverageDeposit.
    ///      The admin must first recover the USDC from the relayer wallet (manual transfer),
    ///      then call this to clear the on-chain accounting.
    function expireAdvance(bytes32 authHash) external onlyAdmin {
        uint256 amount = pendingAdvances[authHash];
        if (amount == 0) revert NoPendingAdvance();
        pendingAdvances[authHash] = 0;
        totalPendingAdvances -= amount;
        emit AdvanceExpired(authHash, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN — RESERVES (moved from main for EIP-170)
    //////////////////////////////////////////////////////////////*/

    event ReservesWithdrawn(address indexed to, uint256 amount);

    /// @notice Withdraw accumulated protocol reserves
    function withdrawReserves(uint256 amount) external onlyAdmin {
        _accrueInterestInline();
        if (amount > totalReserves) amount = totalReserves;
        totalReserves -= amount;
        IERC20(_asset()).safeTransfer(admin, amount);
        emit ReservesWithdrawn(admin, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    LEVERAGE — USDC PULL FOR INITIAL BUY
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );

    struct LeverageAuth {
        address borrower;
        address allowedFrom;
        uint256 tokenId;
        uint256 maxBorrow;
        uint256 nonce;
        uint256 deadline;
    }

    event UsdcPulledForLeverage(address indexed borrower, address indexed from, uint256 amount, uint256 indexed tokenId);
    event PoolAdvancedForLeverage(address indexed borrower, uint256 advanceAmount, uint256 indexed tokenId);

    /// @notice Pull USDC from user's Safe + optionally advance borrow USDC from pool to relayer.
    /// @dev Lives in the extension (via delegatecall) to keep the main contract under EIP-170 size limit.
    ///      Uses the same LeverageAuth + maxBorrow budget as leverageDeposit.
    ///      The advance is unsecured pool USDC sent to the relayer before collateral is deposited.
    ///      It is formalized as a real borrow when leverageDeposit is called (advance offset pattern).
    ///      TRUST MODEL: Same as leverageDeposit — relayer is trusted to buy shares
    ///      and deposit them via leverageDeposit. Relayer rotation is timelocked (6h).
    /// @param auth The user's leverage authorization
    /// @param authSignature The user's EIP-712 signature
    /// @param userAmount USDC to pull from user's Safe to relayer
    /// @param advanceAmount USDC to advance from pool to relayer (formalized as borrow in leverageDeposit)
    function pullUsdcForLeverage(
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        uint256 userAmount,
        uint256 advanceAmount
    ) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (resolvedMarkets[auth.tokenId].resolved) revert MarketResolved();
        if (block.timestamp > auth.deadline) revert IntentExpired();
        if (userAmount == 0 && advanceAmount == 0) revert BorrowTooSmall();

        bytes32 structHash = keccak256(abi.encode(
            LEVERAGE_AUTH_TYPEHASH, auth.borrower, auth.allowedFrom, auth.tokenId,
            auth.maxBorrow, auth.nonce, auth.deadline
        ));
        bytes32 authHash = _hashTypedDataV4Ext(structHash);
        if (ECDSA.recover(authHash, authSignature) != auth.borrower) revert InvalidIntentSignature();

        // Consume nonce on first use (same pattern as leverageDeposit)
        bool isFirstUse = (leverageBorrowUsed[authHash] == 0);
        if (isFirstUse) {
            if (auth.nonce != leverageNonces[auth.borrower]) revert InvalidNonce();
            leverageNonces[auth.borrower]++;
        }

        // Track BOTH user pull + advance against maxBorrow budget
        uint256 newTotal = leverageBorrowUsed[authHash] + userAmount + advanceAmount;
        if (newTotal > auth.maxBorrow) revert ExceedsBorrowBudget();
        leverageBorrowUsed[authHash] = newTotal;

        // Pull USDC from user's Safe to relayer
        if (userAmount > 0) {
            IERC20(_asset()).safeTransferFrom(auth.allowedFrom, msg.sender, userAmount);
            emit UsdcPulledForLeverage(auth.borrower, auth.allowedFrom, userAmount, auth.tokenId);
        }

        // Advance pool USDC to relayer (formalized as borrow in leverageDeposit)
        if (advanceAmount > 0) {
            // Collect operation fee from the advance (spam protection).
            // Fee is charged here (not in _executeBorrow) because the USDC leaves the pool here.
            uint256 fee = operationFee;
            if (advanceAmount <= fee) revert AdvanceTooSmall();
            uint256 netAdvance = advanceAmount - fee;
            operationFeePool += fee;
            emit OperationFeeCollected(auth.borrower, fee);

            // Liquidity check (inline — extension can't call _availableCash)
            uint256 cash = IERC20(_asset()).balanceOf(address(this));
            if (cash > totalReserves) cash -= totalReserves; else cash = 0;
            if (cash > unsettledRedemptions) cash -= unsettledRedemptions; else cash = 0;
            if (cash > operationFeePool) cash -= operationFeePool; else cash = 0;
            if (cash > totalPendingAdvances) cash -= totalPendingAdvances; else cash = 0;
            if (netAdvance > cash) revert InsufficientLiquidity();

            pendingAdvances[authHash] += netAdvance;
            totalPendingAdvances += netAdvance;
            IERC20(_asset()).safeTransfer(msg.sender, netAdvance);
            emit PoolAdvancedForLeverage(auth.borrower, netAdvance, auth.tokenId);
        }
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
}
