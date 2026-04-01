// SPDX-License-Identifier: MIT
// contracts/src/PredmartPoolExtension.sol
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { ICTF } from "./interfaces/ICTF.sol";

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

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error InvalidAddress();
    error InvalidAnchors();
    error TimelockNotReady();
    error NoPendingChange();
    error TimelockCannotDecrease();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error NoPosition();
    error TokenNotRedeemed();
    error AlreadyRedeemed();
    error RedemptionFailed();
    error UseRedemptionFlow();

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
    event BadDebtAbsorbed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 reserve);
    event CollateralRedeemed(uint256 indexed tokenId, uint256 sharesRedeemed, uint256 usdcReceived);
    event RedemptionSettled(address indexed borrower, uint256 indexed tokenId, uint256 debtRepaid, uint256 surplusToUser);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Position {
        uint256 collateralAmount;
        uint256 borrowShares;
        uint256 lastDepositTimestamp;
        uint256 borrowedPrincipal;
    }

    struct MarketResolution {
        bool resolved;
        bool won;
    }

    struct Redemption {
        bool redeemed;
        uint256 totalShares;
        uint256 usdcReceived;
    }

    /*//////////////////////////////////////////////////////////////
              STATE — MUST MATCH PredmartLendingPool EXACTLY
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

    // v1.1.0 — Deleverage loop authorization
    mapping(address => uint256) public deleverageNonces;
    mapping(bytes32 => uint256) public deleverageWithdrawUsed;

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

        uint256 totalLiquidity = IERC20(_asset()).balanceOf(address(this)) + totalBorrowAssets;
        totalLiquidity = totalLiquidity > totalReserves ? totalLiquidity - totalReserves : 0;
        totalLiquidity = totalLiquidity > unsettledRedemptions ? totalLiquidity - unsettledRedemptions : 0;
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
    function closeResolvedPosition(address borrower, uint256 tokenId) external {
        MarketResolution memory resolution = resolvedMarkets[tokenId];
        if (!resolution.resolved) revert MarketNotResolved();

        _accrueInterestInline();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        if (resolution.won) {
            revert UseRedemptionFlow();
        } else {
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
}
