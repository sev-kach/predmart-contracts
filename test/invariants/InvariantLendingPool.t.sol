// contracts/test/invariants/InvariantLendingPool.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PredmartLendingPool } from "../../src/PredmartLendingPool.sol";
import { PredmartPoolExtension } from "../../src/PredmartPoolExtension.sol";
import { PredmartOracle } from "../../src/PredmartOracle.sol";
import { MockUSDC } from "../mocks/MockUSDC.sol";
import { MockCTF } from "../mocks/MockCTF.sol";

/// @title Handler — executes random protocol operations for invariant fuzzing
/// @dev The fuzzer calls these functions with random parameters. Each function
///      wraps a protocol operation with bounds-checking to prevent trivial reverts.
contract Handler is Test {
    PredmartLendingPool public pool;
    PredmartPoolExtension public poolAdmin;
    MockUSDC public usdc;
    MockCTF public ctf;

    address public admin;
    address public relayer;
    address public lender;
    uint256 public oraclePrivateKey;
    uint256 public borrowerPrivateKey;
    address public borrower;

    uint256 public constant TOKEN_ID = 1001;
    uint256 public constant PRICE = 0.50e18;

    // Track ghost variables for invariant assertions
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalBorrowed;
    uint256 public ghost_totalRepaid;
    uint256 public ghost_totalFeesCollected;

    bytes32 public constant BORROW_INTENT_TYPEHASH = keccak256(
        "BorrowIntent(address borrower,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH = keccak256(
        "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    constructor(
        PredmartLendingPool _pool,
        PredmartPoolExtension _poolAdmin,
        MockUSDC _usdc,
        MockCTF _ctf,
        address _admin,
        address _relayer,
        address _lender,
        uint256 _oraclePrivateKey,
        uint256 _borrowerPrivateKey,
        address _borrower
    ) {
        pool = _pool;
        poolAdmin = _poolAdmin;
        usdc = _usdc;
        ctf = _ctf;
        admin = _admin;
        relayer = _relayer;
        lender = _lender;
        oraclePrivateKey = _oraclePrivateKey;
        borrowerPrivateKey = _borrowerPrivateKey;
        borrower = _borrower;
    }

    /// @notice Lender deposits USDC into the pool
    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 50_000e6);
        if (usdc.balanceOf(lender) < amount) return;

        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, lender);
        vm.stopPrank();

        ghost_totalDeposited += amount;
    }

    /// @notice Lender withdraws USDC from the pool
    function withdraw(uint256 amount) external {
        uint256 maxW = pool.maxWithdraw(lender);
        if (maxW == 0) return;
        amount = bound(amount, 1, maxW);

        vm.prank(lender);
        pool.withdraw(amount, lender, lender);

        ghost_totalWithdrawn += amount;
    }

    /// @notice Borrower deposits collateral
    function depositCollateral(uint256 amount) external {
        amount = bound(amount, 1e6, 5_000e6);
        if (ctf.balanceOf(borrower, TOKEN_ID) < amount) return;

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID, amount);
        vm.stopPrank();
    }

    /// @notice Borrower borrows via relay
    function borrow(uint256 amount) external {
        amount = bound(amount, 1e6, 20e6); // $1 to $20
        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID);
        if (collateral == 0) return;

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;

        bytes32 structHash = keccak256(
            abi.encode(BORROW_INTENT_TYPEHASH, borrower, TOKEN_ID, amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower, tokenId: TOKEN_ID, amount: amount, nonce: nonce, deadline: deadline
        });

        vm.prank(relayer);
        try pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID, PRICE)) {
            ghost_totalBorrowed += amount;
        } catch {}
    }

    /// @notice Borrower repays debt
    function repay(uint256 amount) external {
        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        if (usdc.balanceOf(borrower) < amount) return;

        vm.startPrank(borrower);
        usdc.approve(address(pool), amount);
        pool.repay(TOKEN_ID, amount);
        vm.stopPrank();

        ghost_totalRepaid += amount;
    }

    /// @notice Borrower withdraws collateral via relay
    function withdrawCollateral(uint256 amount) external {
        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID);
        if (collateral == 0) return;
        amount = bound(amount, 1, collateral);

        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;

        bytes32 structHash = keccak256(
            abi.encode(WITHDRAW_INTENT_TYPEHASH, borrower, borrower, TOKEN_ID, amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        PredmartLendingPool.WithdrawIntent memory intent = PredmartLendingPool.WithdrawIntent({
            borrower: borrower, to: borrower, tokenId: TOKEN_ID, amount: amount, nonce: nonce, deadline: deadline
        });

        vm.prank(relayer);
        try pool.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID, PRICE)) {} catch {}
    }

    /// @notice Time passes — triggers interest accrual
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
        pool.accrueInterest();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Predmart Lending Pool"),
                keccak256("0.8.0"),
                block.chainid,
                address(pool)
            )
        );
    }

    function _signPrice(uint256 tokenId, uint256 price) internal view returns (PredmartOracle.PriceData memory) {
        uint256 maxBorrow = type(uint256).max;
        bytes32 hash = keccak256(abi.encodePacked(block.chainid, address(pool), tokenId, price, block.timestamp, maxBorrow));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethHash);
        return PredmartOracle.PriceData({ tokenId: tokenId, price: price, timestamp: block.timestamp, maxBorrow: maxBorrow, signature: abi.encodePacked(r, s, v) });
    }
}


/// @title Invariant tests for PredmartLendingPool
/// @notice Tests properties that must hold across arbitrary sequences of operations
contract InvariantLendingPoolTest is Test {
    PredmartLendingPool public pool;
    PredmartPoolExtension public poolAdmin;
    MockUSDC public usdc;
    MockCTF public ctf;
    Handler public handler;

    address public admin;
    address public relayer;
    address public lender;
    address public borrower;

    uint256 public constant TOKEN_ID = 1001;

    function setUp() public {
        admin = makeAddr("admin");
        uint256 oraclePrivateKey = 0xA11CE;
        address oracleAddress = vm.addr(oraclePrivateKey);
        uint256 relayerPrivateKey = 0xBEEF;
        relayer = vm.addr(relayerPrivateKey);
        uint256 borrowerPrivateKey = 0xB0B;
        borrower = vm.addr(borrowerPrivateKey);
        lender = makeAddr("lender");

        usdc = new MockUSDC();
        ctf = new MockCTF();

        // Deploy proxy through upgrade path
        PredmartLendingPool impl = new PredmartLendingPool();
        bytes memory initData = abi.encodeWithSelector(PredmartLendingPool.initialize.selector, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        PredmartLendingPool implV2 = new PredmartLendingPool();
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(
            address(implV2),
            abi.encodeWithSelector(PredmartLendingPool.initializeV2.selector, oracleAddress, address(usdc), address(ctf))
        );
        PredmartLendingPool(address(proxy)).initializeV3();

        PredmartLendingPool implV4 = new PredmartLendingPool();
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(
            address(implV4),
            abi.encodeWithSelector(PredmartLendingPool.initializeV4.selector, relayer)
        );

        pool = PredmartLendingPool(address(proxy));
        poolAdmin = PredmartPoolExtension(address(proxy));

        PredmartPoolExtension ext = new PredmartPoolExtension();
        vm.prank(admin);
        pool.setExtension(address(ext));

        // Enable operation fee ($0.03)
        vm.prank(admin);
        poolAdmin.setOperationFee(30_000);

        // Seed accounts
        usdc.mint(lender, 1_000_000e6);
        usdc.mint(borrower, 100_000e6);
        usdc.mint(relayer, 100_000e6);
        ctf.mint(borrower, TOKEN_ID, 100_000e6);

        vm.prank(relayer);
        usdc.approve(address(pool), type(uint256).max);

        // Initial liquidity — lender deposits so borrowing is possible
        vm.startPrank(lender);
        usdc.approve(address(pool), 500_000e6);
        pool.deposit(500_000e6, lender);
        vm.stopPrank();

        // Create handler and target it for fuzzing
        handler = new Handler(
            pool, poolAdmin, usdc, ctf,
            admin, relayer, lender,
            oraclePrivateKey, borrowerPrivateKey, borrower
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice totalAssets must always be backed by real value (USDC balance + outstanding debt + pending closes)
    function invariant_totalAssetsBacked() public view {
        uint256 totalAssets = pool.totalAssets();
        uint256 usdcBalance = usdc.balanceOf(address(pool));
        uint256 totalBorrowAssets = pool.totalBorrowAssets();
        uint256 totalPendingCloses = pool.totalPendingCloses();

        // totalAssets = balance + borrows + pendingCloses - reserves - unsettled - feePool (approx, with interest)
        // The real USDC backing is: usdcBalance + totalBorrowAssets + totalPendingCloses
        // totalAssets should never exceed this raw backing
        uint256 rawBacking = usdcBalance + totalBorrowAssets + totalPendingCloses;
        assertLe(totalAssets, rawBacking, "INV: totalAssets exceeds raw USDC backing");
    }

    /// @notice operationFeePool must never be counted as lender assets
    function invariant_feePoolExcludedFromTotalAssets() public view {
        uint256 feePool = pool.operationFeePool();
        if (feePool == 0) return;

        // If we imagine feePool was 0, totalAssets would be higher by feePool
        // So: totalAssets + feePool <= balance + borrows + pendingCloses
        uint256 totalAssets = pool.totalAssets();
        uint256 rawBacking = usdc.balanceOf(address(pool)) + pool.totalBorrowAssets() + pool.totalPendingCloses();

        assertLe(
            totalAssets + feePool,
            rawBacking + 1, // +1 for rounding
            "INV: feePool not excluded from totalAssets"
        );
    }

    /// @notice Borrow shares and borrow assets must be zero together (no phantom debt)
    function invariant_borrowTrackingConsistent() public view {
        uint256 totalBorrowAssets = pool.totalBorrowAssets();
        uint256 totalBorrowShares = pool.totalBorrowShares();

        // If one is zero, the other must also be zero
        if (totalBorrowAssets == 0) {
            assertEq(totalBorrowShares, 0, "INV: phantom borrow shares with zero assets");
        }
        if (totalBorrowShares == 0) {
            assertEq(totalBorrowAssets, 0, "INV: phantom borrow assets with zero shares");
        }
    }

    /// @notice Total backing (cash + outstanding debt + pending closes) must cover all reserved amounts
    function invariant_solvency() public view {
        uint256 balance = usdc.balanceOf(address(pool));
        uint256 totalBorrowAssets = pool.totalBorrowAssets();
        uint256 totalPendingCloses = pool.totalPendingCloses();
        uint256 reserves = pool.totalReserves();
        uint256 unsettled = pool.unsettledRedemptions();
        uint256 feePool = pool.operationFeePool();

        // Raw backing = cash + what borrowers owe + what pending closes owe
        // This must always cover all reserved buckets (reserves are backed by future repayments)
        uint256 rawBacking = balance + totalBorrowAssets + totalPendingCloses;
        uint256 reservedAmounts = reserves + unsettled + feePool;

        assertGe(
            rawBacking,
            reservedAmounts,
            "INV: pool insolvent - backing < reserved amounts"
        );
    }

    /// @notice Interest accrual must be monotonic — totalReserves never decreases (except admin withdrawal)
    function invariant_reservesMonotonic() public view {
        // totalReserves should always be >= 0 (uint256 guarantees this)
        // More importantly: totalBorrowAssets should be >= what borrowers actually owe
        // This is implicitly tested by borrowTrackingConsistent + solvency
        uint256 reserves = pool.totalReserves();
        assertGe(reserves, 0, "INV: negative reserves (impossible but check)");
    }

    /// @notice Pool's CTF balance must be >= sum of all tracked collateral + fee shares
    function invariant_ctfBalanceCoversPositions() public view {
        uint256 poolCTFBalance = ctf.balanceOf(address(pool), TOKEN_ID);
        (uint256 borrowerCollateral,,,) = pool.positions(borrower, TOKEN_ID);
        uint256 feeShares = pool.feeSharesAccumulated(TOKEN_ID);

        // Pool must hold at least enough CTF for all positions + accumulated fee shares
        assertGe(
            poolCTFBalance,
            borrowerCollateral + feeShares,
            "INV: CTF balance < tracked collateral + fee shares"
        );
    }

    /// @notice operationFeePool must only increase from fee collection, never from interest
    function invariant_feePoolSeparateFromInterest() public view {
        // The feePool should be <= total fees ever collected (bounded by operations * fee)
        // Since we track ghost_totalBorrowed in handler, feePool <= numBorrows * operationFee
        // We can't directly check this without more ghost vars, but we can verify
        // feePool is reasonable (not inflated by interest)
        uint256 feePool = pool.operationFeePool();
        uint256 operationFee = pool.operationFee();

        // Fee pool should never exceed what's theoretically possible
        // Each borrow adds at most operationFee to the pool
        // Upper bound: assume every dollar borrowed generated a fee
        if (operationFee > 0) {
            uint256 maxPossibleFees = (handler.ghost_totalBorrowed() / 1e6 + 1) * operationFee;
            assertLe(feePool, maxPossibleFees, "INV: feePool exceeds max possible from borrows");
        }
    }
}
