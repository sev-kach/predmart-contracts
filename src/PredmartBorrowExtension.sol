// SPDX-License-Identifier: MIT
// contracts/src/PredmartBorrowExtension.sol
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PredmartPoolLib } from "./PredmartPoolLib.sol";
import { PredmartOracle } from "./PredmartOracle.sol";
import { ICTF } from "./interfaces/ICTF.sol";
import {
    Position, MarketResolution, Redemption, PendingClose, PendingLiquidation,
    InvalidAddress, NoPosition, NotRelayer, TokenFrozen,
    InterestAccrued, OperationFeeCollected, CollateralDeposited
} from "./PredmartTypes.sol";

/// @title PredmartBorrowExtension
/// @notice Hosts user-facing entry points for borrowing, leveraging, depositing collateral,
///         and withdrawing — plus their internal helpers. Reached via delegatecall from
///         PredmartLendingPool's selector-routing fallback. Shares the same proxy storage.
/// @dev    State variables MUST be in the exact same order as PredmartLendingPool and
///         PredmartPoolExtension. See storage section below for the canonical order.
contract PredmartBorrowExtension {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant NUM_ANCHORS = 7;
    uint256 public constant MAX_RELAY_PRICE_AGE = 60 seconds;
    uint256 public constant MIN_BORROW = 1e6; // $1 USDC minimum debt — must match LendingPool

    bytes32 public constant BORROW_INTENT_TYPEHASH = keccak256(
        "BorrowIntent(address borrower,address recipient,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH = keccak256(
        "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,address recipient,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant DEPOSIT_COLLATERAL_FROM_TYPEHASH = keccak256(
        "DepositCollateralFromAuth(address from,address creditTo,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error IntentExpired();
    error InvalidNonce();
    error InvalidIntentSignature();
    error InsufficientLiquidity();
    error ExceedsLTV();
    error BorrowTooSmall();
    error ExceedsTokenCap();
    error DepthCapExceeded();
    error MarketResolved();
    error PositionHasPendingClose();
    error AdvanceTooSmall();
    error ExceedsBorrowBudget();
    error AuthAlreadyUsed();
    error NotLeverageModule();
    error ProtocolPaused();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Borrowed(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 indexed tokenId, uint256 amount);
    event UsdcPulledForLeverage(address indexed borrower, address indexed from, uint256 amount, uint256 indexed tokenId);
    event PoolAdvancedForLeverage(address indexed borrower, uint256 advanceAmount, uint256 indexed tokenId);
    event StaleInitialEquityCleared(address indexed borrower, uint256 indexed tokenId, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct BorrowIntent {
        address borrower;
        address recipient;  // V2-native — where borrowed USDC.e is delivered (user's Safe)
        uint256 tokenId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct WithdrawIntent {
        address borrower;
        address to;
        uint256 tokenId;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    struct LeverageAuth {
        address borrower;
        address allowedFrom;
        address recipient;  // V2-native — destination for redemption surplus (user's Safe)
        uint256 tokenId;
        uint256 maxBorrow;
        uint256 nonce;
        uint256 deadline;
    }

    struct LeverageDepositData {
        address from;         // Address holding CTF shares (user's Safe or relayer)
        address borrowTo;     // Destination for borrowed USDC (user's Safe or relayer)
        uint256 depositAmount;
        uint256 borrowAmount;
    }

    /*//////////////////////////////////////////////////////////////
              STATE — MUST MATCH PredmartLendingPool / PredmartPoolExtension EXACTLY
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
    address public extension;
    address public pendingAdmin;
    uint256 public pendingAdminExecAfter;

    // v1.0.0 — Leverage
    mapping(address => uint256) public leverageNonces;
    mapping(bytes32 => uint256) public leverageBorrowUsed;

    // v1.1.0 — DEPRECATED
    mapping(address => uint256) internal deleverageNonces;
    mapping(bytes32 => uint256) internal deleverageWithdrawUsed;

    // v1.2.0 — Pool-funded flash close
    mapping(address => mapping(uint256 => uint256)) public closeNonces;
    uint256 public totalPendingCloses;
    mapping(address => mapping(uint256 => PendingClose)) public pendingCloses;

    // v1.3.0 — Operation fee
    uint256 public operationFee;
    uint256 public operationFeePool;
    mapping(uint256 => uint256) public feeSharesAccumulated;

    // v1.5.0 — Leverage advance
    mapping(bytes32 => uint256) public pendingAdvances;
    uint256 public totalPendingAdvances;
    uint256 private _advanceOffset;

    // v1.7.0 — NegRisk support
    address public negRiskAdapter;

    // v2.0.0 — Pending liquidations
    mapping(address => mapping(uint256 => PendingLiquidation)) public pendingLiquidations;
    uint256 public totalPendingLiquidations;

    // v2.0.0 — Protocol fee accumulator
    uint256 public protocolFeePool;

    // v2.0.0 — Liquidator wallet
    address public liquidator;

    // v2.1.0 — Advance timestamps
    mapping(bytes32 => uint256) public pendingAdvanceTimestamps;

    // v2.2.0 — Timelocked liquidator rotation
    address public pendingLiquidator;
    uint256 public pendingLiquidatorExecAfter;

    // v2.3.0 — EIP-1271 signature auth for depositCollateralFrom
    mapping(address => uint256) public depositCollateralFromNonces;

    // v2.3.1 — Timelocked extension rotation
    address public pendingExtension;
    uint256 public pendingExtensionExecAfter;

    // v2.4.0 — Deposit-only call replay tracking
    mapping(bytes32 => bool) public leverageDepositOnlyConsumed;

    // v2.5.0 — Atomic-execute leverage module + timelocked rotation
    address public leverageModule;
    address public pendingLeverageModule;
    uint256 public pendingLeverageModuleExecAfter;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL HELPERS (duplicated)
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC-4626 asset() via OZ namespaced storage slot.
    function _asset() internal view returns (address) {
        bytes32 slot = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
        address asset_;
        assembly { asset_ := sload(slot) }
        return asset_;
    }

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

    function _toBorrowShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets.mulDiv(totalBorrowShares + 1e6, totalBorrowAssets + 1, rounding);
    }

    function _toBorrowAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        return shares.mulDiv(totalBorrowAssets + 1, totalBorrowShares + 1e6, rounding);
    }

    function _availableCash() internal view returns (uint256) {
        uint256 cash = IERC20(_asset()).balanceOf(address(this));
        cash = cash > totalReserves ? cash - totalReserves : 0;
        cash = cash > unsettledRedemptions ? cash - unsettledRedemptions : 0;
        cash = cash > operationFeePool ? cash - operationFeePool : 0;
        cash = cash > protocolFeePool ? cash - protocolFeePool : 0;
        return cash;
    }

    function _getLTV(uint256 price) internal view returns (uint256) {
        return PredmartPoolLib.interpolate(priceAnchors, ltvAnchors, price);
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("Predmart Lending Pool"),
            keccak256("0.8.0"),
            block.chainid,
            address(this)
        ));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /*//////////////////////////////////////////////////////////////
                       USER ENTRY — BORROW VIA RELAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Borrow USDC via meta-transaction relay. Only callable by the relayer.
    function borrowViaRelay(
        BorrowIntent calldata intent,
        bytes calldata intentSignature,
        PredmartOracle.PriceData calldata priceData
    ) external whenNotPaused {
        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.nonce != borrowNonces[intent.borrower]) revert InvalidNonce();

        bytes32 structHash = keccak256(abi.encode(
            BORROW_INTENT_TYPEHASH, intent.borrower, intent.recipient,
            intent.tokenId, intent.amount, intent.nonce, intent.deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, digest, intentSignature)) {
            revert InvalidIntentSignature();
        }

        borrowNonces[intent.borrower]++;

        if (priceData.tokenId != intent.tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterestInline();
        _executeBorrow(intent.borrower, intent.tokenId, intent.amount, price, priceData.maxBorrow,
                       intent.recipient, intent.recipient, true);
    }

    /*//////////////////////////////////////////////////////////////
                       USER ENTRY — LEVERAGE DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function leverageDeposit(
        LeverageAuth calldata auth,
        bytes calldata authSignature,
        bytes calldata fromSignature,
        LeverageDepositData calldata data,
        PredmartOracle.PriceData calldata priceData
    ) external whenNotPaused {
        if (data.from != auth.allowedFrom && data.from != relayer) revert InvalidAddress();
        if (data.borrowTo != auth.allowedFrom && data.borrowTo != relayer) revert InvalidAddress();

        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > auth.deadline) revert IntentExpired();

        bytes32 structHash = keccak256(abi.encode(
            LEVERAGE_AUTH_TYPEHASH, auth.borrower, auth.allowedFrom, auth.recipient,
            auth.tokenId, auth.maxBorrow, auth.nonce, auth.deadline
        ));
        bytes32 authHash = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(auth.borrower, authHash, authSignature)) revert InvalidIntentSignature();

        if (data.depositAmount > 0 && data.from != relayer) {
            _verifyAllowedFromSig(auth.allowedFrom, auth.borrower, authHash, fromSignature);
        }

        _accrueInterestInline();

        if (data.depositAmount > 0) {
            if (data.borrowAmount == 0) {
                if (leverageBorrowUsed[authHash] > 0) revert AuthAlreadyUsed();
                if (leverageDepositOnlyConsumed[authHash]) revert AuthAlreadyUsed();
                leverageDepositOnlyConsumed[authHash] = true;

                // Snapshot deposit-time price into initialEquity. Without this, a
                // position created via deposit-only has initialEquity = 0 and the
                // profit-fee guard `initialEquity > 0` skips fee collection on
                // win-redemption. The leverageBorrowUsed == 0 gate above guarantees
                // no prior pull has credited userAmount, so this addition cannot
                // double-count the user's contribution.
                if (priceData.tokenId != auth.tokenId) revert PredmartOracle.TokenIdMismatch();
                uint256 priceDep = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
                Position storage posDep = positions[auth.borrower][auth.tokenId];
                posDep.initialEquity += data.depositAmount.mulDiv(priceDep, 1e18);
                // Also seed pos.recipient if unset — settleRedemption requires it as
                // the destination for win-market surplus. Borrow paths set this in
                // _executeBorrow; the deposit-only path needs its own bootstrap.
                if (posDep.recipient == address(0)) {
                    if (auth.recipient == address(0)) revert InvalidAddress();
                    posDep.recipient = auth.recipient;
                }
            }
            _depositCollateral(auth.borrower, data.from, auth.tokenId, data.depositAmount, data.depositAmount);
        }

        if (data.borrowAmount > 0) {
            bool isFirstBorrow = (leverageBorrowUsed[authHash] == 0);
            if (isFirstBorrow) {
                if (auth.nonce != leverageNonces[auth.borrower]) revert InvalidNonce();
                leverageNonces[auth.borrower]++;
            }

            uint256 advance = pendingAdvances[authHash];
            if (advance > 0) {
                uint256 settled = advance > data.borrowAmount ? data.borrowAmount : advance;
                pendingAdvances[authHash] = advance - settled;
                totalPendingAdvances -= settled;
                if (pendingAdvances[authHash] == 0) delete pendingAdvanceTimestamps[authHash];
                _advanceOffset = settled;
            }

            uint256 effectiveNewBorrow = data.borrowAmount > advance ? data.borrowAmount - advance : 0;
            uint256 newTotal = leverageBorrowUsed[authHash] + effectiveNewBorrow;
            if (newTotal > auth.maxBorrow) revert ExceedsBorrowBudget();
            leverageBorrowUsed[authHash] = newTotal;

            if (priceData.tokenId != auth.tokenId) revert PredmartOracle.TokenIdMismatch();
            uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);
            _executeBorrow(auth.borrower, auth.tokenId, data.borrowAmount, price, priceData.maxBorrow,
                           data.borrowTo, auth.recipient, isFirstBorrow);

            _advanceOffset = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                  USER ENTRY — DEPOSIT COLLATERAL FROM
    //////////////////////////////////////////////////////////////*/

    function depositCollateralFrom(
        address from,
        address creditTo,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        PredmartOracle.PriceData calldata priceData
    ) external whenNotPaused {
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

        if (priceData.tokenId != tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        uint256 feeInShares;
        if (operationFee > 0 && msg.sender == relayer) {
            feeInShares = operationFee.mulDiv(1e18, price, Math.Rounding.Ceil);
            if (feeInShares > amount) feeInShares = amount;
            feeSharesAccumulated[tokenId] += feeInShares;
            emit OperationFeeCollected(from, operationFee);
        }

        uint256 credited = amount - feeInShares;
        _depositCollateral(creditTo, from, tokenId, amount, credited);

        positions[creditTo][tokenId].initialEquity += credited * price / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                       USER ENTRY — WITHDRAW VIA RELAY
    //////////////////////////////////////////////////////////////*/

    function withdrawViaRelay(
        WithdrawIntent calldata intent,
        bytes calldata intentSignature,
        PredmartOracle.PriceData calldata priceData
    ) external whenNotPaused {
        if (msg.sender != relayer) revert NotRelayer();
        if (block.timestamp > intent.deadline) revert IntentExpired();
        if (intent.nonce != withdrawNonces[intent.borrower]) revert InvalidNonce();

        bytes32 structHash = keccak256(abi.encode(
            WITHDRAW_INTENT_TYPEHASH, intent.borrower, intent.to, intent.tokenId,
            intent.amount, intent.nonce, intent.deadline
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(intent.borrower, digest, intentSignature)) {
            revert InvalidIntentSignature();
        }

        withdrawNonces[intent.borrower]++;

        if (priceData.tokenId != intent.tokenId) revert PredmartOracle.TokenIdMismatch();
        uint256 price = PredmartOracle.verifyPrice(priceData, oracle, address(this), MAX_RELAY_PRICE_AGE);

        _accrueInterestInline();
        _withdrawCollateral(intent.borrower, intent.tokenId, intent.amount, intent.to, price);
    }

    /*//////////////////////////////////////////////////////////////
                       MODULE ENTRY — pullUsdcForLeverage
    //////////////////////////////////////////////////////////////*/

    /// @notice Module-only entry: pool-side accounting + USDC.e advance for a leverage open.
    function pullUsdcForLeverage(
        LeverageAuth calldata auth,
        uint256 userAmount,
        uint256 advanceAmount
    ) external {
        if (msg.sender != leverageModule) revert NotLeverageModule();
        if (paused) revert ProtocolPaused();
        if (resolvedMarkets[auth.tokenId].resolved) revert MarketResolved();
        if (frozenTokens[auth.tokenId]) revert TokenFrozen();
        if (block.timestamp > auth.deadline) revert IntentExpired();
        if (userAmount == 0 && advanceAmount == 0) revert BorrowTooSmall();

        bytes32 structHash = keccak256(abi.encode(
            LEVERAGE_AUTH_TYPEHASH, auth.borrower, auth.allowedFrom, auth.recipient,
            auth.tokenId, auth.maxBorrow, auth.nonce, auth.deadline
        ));
        bytes32 authHash = _hashTypedDataV4(structHash);

        bool isFirstUse = (leverageBorrowUsed[authHash] == 0);
        if (isFirstUse) {
            if (auth.nonce != leverageNonces[auth.borrower]) revert InvalidNonce();
            leverageNonces[auth.borrower]++;
        }

        uint256 newTotal = leverageBorrowUsed[authHash] + userAmount + advanceAmount;
        if (newTotal > auth.maxBorrow) revert ExceedsBorrowBudget();
        leverageBorrowUsed[authHash] = newTotal;

        if (userAmount > 0) {
            Position storage pos = positions[auth.borrower][auth.tokenId];
            if (pos.collateralAmount == 0 && pos.borrowShares == 0 && pos.initialEquity > 0) {
                emit StaleInitialEquityCleared(auth.borrower, auth.tokenId, pos.initialEquity);
                pos.initialEquity = 0;
            }
            pos.initialEquity += userAmount;
            emit UsdcPulledForLeverage(auth.borrower, auth.allowedFrom, userAmount, auth.tokenId);
        }

        if (advanceAmount > 0) {
            uint256 fee = operationFee;
            if (advanceAmount <= fee) revert AdvanceTooSmall();
            uint256 netAdvance = advanceAmount - fee;
            operationFeePool += fee;
            emit OperationFeeCollected(auth.borrower, fee);

            if (netAdvance > _availableCash()) revert InsufficientLiquidity();

            pendingAdvances[authHash] += advanceAmount;
            totalPendingAdvances += advanceAmount;
            pendingAdvanceTimestamps[authHash] = block.timestamp;
            IERC20(_asset()).safeTransfer(relayer, netAdvance);
            emit PoolAdvancedForLeverage(auth.borrower, netAdvance, auth.tokenId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL — _executeBorrow
    //////////////////////////////////////////////////////////////*/

    /// @dev Core borrow execution — shared by borrowViaRelay (USDC→Safe) and leverageDeposit (USDC→relayer).
    function _executeBorrow(
        address borrower, uint256 tokenId, uint256 amount,
        uint256 price, uint256 maxBorrowDepthCap, address sendTo,
        address positionRecipient,
        bool chargeFee
    ) internal {
        if (frozenTokens[tokenId]) revert TokenFrozen();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();

        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();

        uint256 currentDebt = pos.borrowShares > 0
            ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
            : 0;
        uint256 collateralValue = pos.collateralAmount.mulDiv(price, 1e18);
        uint256 ltv = _getLTV(price);
        uint256 maxBorrow = collateralValue.mulDiv(ltv, 1e18);
        if (currentDebt + amount > maxBorrow) revert ExceedsLTV();
        if (currentDebt + amount < MIN_BORROW) revert BorrowTooSmall();

        if (poolCapBps > 0) {
            uint256 cash = IERC20(_asset()).balanceOf(address(this)) + totalBorrowAssets;
            uint256 tokenCap = cash.mulDiv(poolCapBps, 10000);
            if (totalBorrowedPerToken[tokenId] + amount > tokenCap) revert ExceedsTokenCap();
        }

        if (totalBorrowedPerToken[tokenId] + amount > maxBorrowDepthCap) revert DepthCapExceeded();

        uint256 offset = _advanceOffset;
        if (offset > amount) offset = amount;
        if (amount - offset > _availableCash()) revert InsufficientLiquidity();

        uint256 shares = _toBorrowShares(amount, Math.Rounding.Ceil);

        pos.borrowShares += shares;
        pos.borrowedPrincipal += amount;
        totalBorrowAssets += amount;
        totalBorrowShares += shares;
        totalBorrowedPerToken[tokenId] += amount;

        if (pos.recipient == address(0)) {
            if (positionRecipient == address(0)) revert InvalidAddress();
            pos.recipient = positionRecipient;
        }

        if (pos.initialEquity == 0) {
            uint256 totalDebt = _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil);
            pos.initialEquity = collateralValue > totalDebt ? collateralValue - totalDebt : 0;
        } else {
            uint256 extracted = amount > offset ? amount - offset : 0;
            if (extracted > 0) {
                pos.initialEquity = pos.initialEquity > extracted ? pos.initialEquity - extracted : 0;
            }
        }

        uint256 fee = (chargeFee && offset == 0) ? operationFee : 0;
        if (fee > 0) {
            operationFeePool += fee;
            emit OperationFeeCollected(borrower, fee);
        }
        uint256 deductions = fee + offset;
        uint256 toSend = amount > deductions ? amount - deductions : 0;
        if (toSend > 0) {
            IERC20(_asset()).safeTransfer(sendTo, toSend);
        }

        emit Borrowed(borrower, tokenId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL — _verifyAllowedFromSig
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                       INTERNAL — _depositCollateral
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                       INTERNAL — _withdrawCollateral
    //////////////////////////////////////////////////////////////*/

    function _withdrawCollateral(
        address borrower,
        uint256 tokenId,
        uint256 amount,
        address to,
        uint256 price
    ) internal {
        Position storage pos = positions[borrower][tokenId];
        if (pos.collateralAmount == 0) revert NoPosition();
        if (amount > pos.collateralAmount) revert InsufficientLiquidity();
        if (resolvedMarkets[tokenId].resolved) revert MarketResolved();
        if (pendingCloses[borrower][tokenId].deadline != 0) revert PositionHasPendingClose();

        pos.collateralAmount -= amount;

        uint256 currentDebt = pos.borrowShares > 0
            ? _toBorrowAssets(pos.borrowShares, Math.Rounding.Ceil)
            : 0;
        if (currentDebt > 0) {
            uint256 collateralValue = pos.collateralAmount.mulDiv(price, 1e18);
            uint256 ltv = _getLTV(price);
            uint256 maxBorrow = collateralValue.mulDiv(ltv, 1e18);
            if (currentDebt > maxBorrow) revert ExceedsLTV();
        }

        // initialEquity reduction: track withdrawn USD value, capped at current initialEquity
        uint256 withdrawnValue = amount.mulDiv(price, 1e18);
        if (pos.initialEquity > withdrawnValue) {
            pos.initialEquity -= withdrawnValue;
        } else {
            pos.initialEquity = 0;
        }

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
}
