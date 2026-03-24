// SPDX-License-Identifier: MIT
// contracts/src/PredmartPoolExtension.sol
pragma solidity ^0.8.24;

import { PredmartPoolLib } from "./PredmartPoolLib.sol";

/// @title PredmartPoolExtension
/// @notice Admin and governance functions for PredmartLendingPool.
///         Called via delegatecall from the main contract's fallback() — shares the same storage.
///         This pattern keeps the main contract under the 24 KB EIP-170 size limit.
/// @dev CRITICAL: State variables MUST be in the exact same order as PredmartLendingPool.
///      OZ 5.x upgradeable contracts use ERC-7201 namespaced storage (no regular slots),
///      so custom variables start at slot 0 in both contracts.
contract PredmartPoolExtension {

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant NUM_ANCHORS = 7;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error InvalidAddress();
    error InvalidAnchors();
    error TimelockNotReady();
    error NoPendingChange();
    error TimelockCannotDecrease();

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
    uint256 public timelockDelay;
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
}
