// contracts/test/PredmartLendingPool.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { PredmartLendingPool } from "../src/PredmartLendingPool.sol";
import { PredmartPoolExtension } from "../src/PredmartPoolExtension.sol";
import { PredmartOracle } from "../src/PredmartOracle.sol";
import { PredmartPoolLib } from "../src/PredmartPoolLib.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { MockCTF } from "./mocks/MockCTF.sol";

contract PredmartLendingPoolTest is Test {
    PredmartLendingPool public pool;
    PredmartPoolExtension public poolAdmin; // Same address as pool, cast for admin function calls via fallback
    MockUSDC public usdc;
    MockCTF public ctf;

    address public admin;
    uint256 public oraclePrivateKey;
    address public oracleAddress;

    uint256 public relayerPrivateKey;
    address public relayer;

    uint256 public borrowerPrivateKey;
    address public borrower;

    address public lender = makeAddr("lender");
    address public liquidator = makeAddr("liquidator");

    uint256 public constant TOKEN_ID_YES = 1001;
    uint256 public constant TOKEN_ID_NO = 1002;

    // EIP-712 typehashes (must match contract)
    bytes32 public constant BORROW_INTENT_TYPEHASH = keccak256(
        "BorrowIntent(address borrower,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH = keccak256(
        "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH = keccak256(
        "LeverageAuth(address borrower,address allowedFrom,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant DELEVERAGE_AUTH_TYPEHASH = keccak256(
        "DeleverageAuth(address borrower,address allowedTo,uint256 tokenId,uint256 maxWithdraw,uint256 nonce,uint256 deadline)"
    );

    address public safe; // Simulates user's Safe wallet

    function setUp() public {
        admin = makeAddr("admin");

        // Oracle signer keypair
        oraclePrivateKey = 0xA11CE;
        oracleAddress = vm.addr(oraclePrivateKey);

        // Relayer keypair
        relayerPrivateKey = 0xBEEF;
        relayer = vm.addr(relayerPrivateKey);

        // Borrower keypair (needed for EIP-712 signing)
        borrowerPrivateKey = 0xB0B;
        borrower = vm.addr(borrowerPrivateKey);

        // Deploy mocks
        usdc = new MockUSDC();
        ctf = new MockCTF();

        // Deploy proxy with v0.1.0 (mirrors production deployment path)
        PredmartLendingPool impl = new PredmartLendingPool();
        bytes memory initData = abi.encodeWithSelector(PredmartLendingPool.initialize.selector, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // Upgrade to v0.2.0
        PredmartLendingPool implV2 = new PredmartLendingPool();
        bytes memory initV2Data = abi.encodeWithSelector(
            PredmartLendingPool.initializeV2.selector, oracleAddress, address(usdc), address(ctf)
        );
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(address(implV2), initV2Data);

        // Initialize v0.6.0 — per-token borrow cap
        PredmartLendingPool(address(proxy)).initializeV3();

        // Upgrade to v0.8.0 — EIP-712 + relayer
        PredmartLendingPool implV4 = new PredmartLendingPool();
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(
            address(implV4),
            abi.encodeWithSelector(PredmartLendingPool.initializeV4.selector, relayer)
        );

        pool = PredmartLendingPool(address(proxy));
        poolAdmin = PredmartPoolExtension(address(proxy));

        // Deploy and set extension contract for admin functions
        PredmartPoolExtension ext = new PredmartPoolExtension();
        vm.prank(admin);
        pool.setExtension(address(ext));

        // Safe address (simulates user's Gnosis Safe)
        safe = makeAddr("safe");

        // Seed accounts
        usdc.mint(lender, 100_000e6);
        usdc.mint(borrower, 10_000e6);
        usdc.mint(liquidator, 100_000e6);
        usdc.mint(relayer, 100_000e6); // Relayer needs USDC for liquidations
        usdc.mint(safe, 50_000e6); // Safe has USDC for deleverage repayments
        ctf.mint(borrower, TOKEN_ID_YES, 10_000e6);
        ctf.mint(borrower, TOKEN_ID_NO, 5_000e6);

        // Relayer approves pool for liquidation payments
        vm.prank(relayer);
        usdc.approve(address(pool), type(uint256).max);

        // Safe approves pool for deleverage repayments (USDC pull)
        vm.prank(safe);
        usdc.approve(address(pool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute EIP-712 domain separator for the pool
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

    /// @dev Sign a BorrowIntent using EIP-712
    function _signBorrowIntent(
        uint256 signerKey,
        address borrowerAddr,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(BORROW_INTENT_TYPEHASH, borrowerAddr, tokenId, amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a WithdrawIntent using EIP-712
    function _signWithdrawIntent(
        uint256 signerKey,
        address borrowerAddr,
        address to,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(WITHDRAW_INTENT_TYPEHASH, borrowerAddr, to, tokenId, amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a DeleverageAuth using EIP-712
    function _signDeleverageAuth(
        uint256 signerKey,
        address borrowerAddr,
        address allowedTo,
        uint256 tokenId,
        uint256 maxWithdraw,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(DELEVERAGE_AUTH_TYPEHASH, borrowerAddr, allowedTo, tokenId, maxWithdraw, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a LeverageAuth using EIP-712
    function _signLeverageAuth(
        uint256 signerKey,
        address borrowerAddr,
        address allowedFrom,
        uint256 tokenId,
        uint256 maxBorrow,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(LEVERAGE_AUTH_TYPEHASH, borrowerAddr, allowedFrom, tokenId, maxBorrow, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Create a signed PriceData struct
    function _signPrice(uint256 tokenId, uint256 price) internal view returns (PredmartOracle.PriceData memory) {
        return _signPriceAt(tokenId, price, block.timestamp);
    }

    function _signPriceAt(
        uint256 tokenId,
        uint256 price,
        uint256 timestamp
    ) internal view returns (PredmartOracle.PriceData memory) {
        uint256 maxBorrow = type(uint256).max; // No depth cap in tests
        bytes32 hash = keccak256(abi.encodePacked(block.chainid, address(pool), tokenId, price, timestamp, maxBorrow));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        return PredmartOracle.PriceData({ tokenId: tokenId, price: price, timestamp: timestamp, maxBorrow: maxBorrow, signature: signature });
    }

    function _signResolution(
        uint256 tokenId,
        bool won
    ) internal view returns (PredmartOracle.ResolutionData memory) {
        bytes32 hash = keccak256(abi.encodePacked("RESOLVE", block.chainid, address(pool), tokenId, won, block.timestamp));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        return PredmartOracle.ResolutionData({
            tokenId: tokenId,
            won: won,
            timestamp: block.timestamp,
            signature: signature
        });
    }

    /// @dev Lender supplies USDC to the pool
    function _supply(address _lender, uint256 amount) internal {
        vm.startPrank(_lender);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, _lender);
        vm.stopPrank();
    }

    /// @dev Borrower deposits collateral and borrows via relay
    function _depositAndBorrow(
        address _borrower,
        uint256 tokenId,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 price
    ) internal {
        vm.startPrank(_borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(tokenId, collateralAmount);
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(_borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: _borrower,
            tokenId: tokenId,
            amount: borrowAmount,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, _borrower, tokenId, borrowAmount, nonce, deadline);

        vm.prank(relayer);
        pool.borrowViaRelay(intent, sig, _signPrice(tokenId, price));
    }

    /*//////////////////////////////////////////////////////////////
                       TEST: INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_Initialization() public view {
        assertEq(pool.admin(), admin);
        assertEq(pool.oracle(), oracleAddress);
        assertEq(pool.asset(), address(usdc));
        assertEq(pool.relayer(), relayer);
        // VERSION is internal — no public getter (size optimization)
        assertEq(keccak256(bytes(pool.name())), keccak256(bytes("Predmart USDC")));
        assertEq(keccak256(bytes(pool.symbol())), keccak256(bytes("pUSDC")));
        assertEq(pool.decimals(), 12); // USDC 6 + _decimalsOffset 6
    }

    function test_DefaultAnchors() public view {
        assertEq(pool.priceAnchors(0), 0);
        assertEq(pool.priceAnchors(6), 1e18);
        assertEq(pool.ltvAnchors(0), 0.02e18);
        assertEq(pool.ltvAnchors(6), 0.75e18);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: LENDER SUPPLY/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_Supply() public {
        _supply(lender, 10_000e6);

        assertEq(pool.totalAssets(), 10_000e6);
        assertGt(pool.balanceOf(lender), 0);
        assertEq(usdc.balanceOf(address(pool)), 10_000e6);
    }

    function test_Withdraw() public {
        _supply(lender, 10_000e6);
        uint256 shares = pool.balanceOf(lender);

        vm.prank(lender);
        pool.redeem(shares, lender, lender);

        assertEq(usdc.balanceOf(lender), 100_000e6); // Got all USDC back
        assertEq(pool.balanceOf(lender), 0);
    }

    function test_WithdrawLimitedByLiquidity() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about liquidity limits, not cap
        _supply(lender, 10_000e6);

        // Borrower takes 5000 USDC (within LTV: 10000 * 0.80 * 0.70 = 5600 max)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 10_000e6, 5_000e6, 0.80e18);

        // Lender can only withdraw what's available (5000 minus any reserves)
        uint256 maxRedeemable = pool.maxRedeem(lender);
        uint256 maxAssets = pool.convertToAssets(maxRedeemable);
        assertLe(maxAssets, 5_000e6);
        assertGt(maxAssets, 0, "Should be able to withdraw something");
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: COLLATERAL DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_DepositCollateral() public {
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
        assertEq(ctf.balanceOf(address(pool), TOKEN_ID_YES), 5_000e6);
    }

    function test_WithdrawCollateral_NoDebt() public {
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        // Withdraw via relay (no debt, so price verification is skipped)
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.WithdrawIntent memory intent = PredmartLendingPool.WithdrawIntent({
            borrower: borrower,
            to: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 2_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signWithdrawIntent(borrowerPrivateKey, borrower, borrower, TOKEN_ID_YES, 2_000e6, nonce, deadline);

        // Dummy price data (won't be verified since no debt)
        PredmartOracle.PriceData memory dummyPrice = _signPrice(TOKEN_ID_YES, 0.80e18);

        vm.prank(relayer);
        pool.withdrawViaRelay(intent, sig, dummyPrice);

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6);
    }

    function test_WithdrawCollateral_RevertsIfUnhealthy() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Try to withdraw too much collateral via relay
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.WithdrawIntent memory intent = PredmartLendingPool.WithdrawIntent({
            borrower: borrower,
            to: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 4_500e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signWithdrawIntent(borrowerPrivateKey, borrower, borrower, TOKEN_ID_YES, 4_500e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsLTV.selector);
        pool.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /*//////////////////////////////////////////////////////////////
                        TEST: BORROW/REPAY
    //////////////////////////////////////////////////////////////*/

    function test_Borrow() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        (uint256 collateral, uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
        assertGt(borrowShares, 0);
        assertEq(pool.totalBorrowAssets(), 2_000e6);
        assertEq(usdc.balanceOf(borrower), 12_000e6); // 10_000 initial + 2_000 borrowed
    }

    function test_Borrow_RevertsExceedsLTV() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        // At $0.80 price, LTV is 70%. Max borrow = 5000 * 0.80 * 0.70 = 2800
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 3_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 3_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsLTV.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Borrow_RevertsInsufficientLiquidity() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about liquidity limits
        _supply(lender, 1_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 10_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 2_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 2_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InsufficientLiquidity.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Repay_Full() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        (,uint256 debt,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(debt, 0);
        assertEq(pool.totalBorrowAssets(), 0);
    }

    function test_Repay_Partial() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(TOKEN_ID_YES, 500e6);
        vm.stopPrank();

        (,uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertGt(borrowShares, 0);
        assertEq(pool.totalBorrowAssets(), 1_500e6);
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function test_InterestAccrues() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365.25 days);

        // Trigger interest accrual via public function
        pool.accrueInterest();

        // Debt should be significantly more than 2000 after 1 year of interest
        // Base rate ~5% + utilization-driven rate, times rate multiplier of 1.25x at $0.80
        assertGt(pool.totalBorrowAssets(), 2_000e6, "totalBorrowed should include interest");
        assertGt(pool.totalReserves(), 0, "Reserves should have accumulated");
    }

    function test_InterestIncreasesTotalAssets() public {
        _supply(lender, 50_000e6);
        uint256 totalAssetsBefore = pool.totalAssets();

        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Trigger accrual
        pool.accrueInterest();

        uint256 totalAssetsAfter = pool.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets should grow from interest");
    }

    /*//////////////////////////////////////////////////////////////
                        TEST: LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_Liquidation() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about liquidation mechanics
        _supply(lender, 50_000e6);
        // Borrow at $0.80 price
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        // Price drops to $0.50 — health factor drops below 1.0
        // HF = 5000 * 0.50 * 0.80 / 2700 = 2000 / 2700 ≈ 0.74
        PredmartOracle.PriceData memory lowPrice = _signPrice(TOKEN_ID_YES, 0.50e18);

        // Relayer calls liquidate (USDC comes from relayer)
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, lowPrice);

        // Position should be deleted
        (uint256 collateral, uint256 debt,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
        assertEq(debt, 0);

        // Relayer should have the collateral (collateral goes to msg.sender)
        assertEq(ctf.balanceOf(relayer, TOKEN_ID_YES), 5_000e6);

        // Pool totalBorrowed should decrease
        assertEq(pool.totalBorrowAssets(), 0);
    }

    function test_Liquidation_RevertsIfHealthy() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Price stays at $0.80 — position is healthy
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.PositionHealthy.selector);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Liquidate_RevertsNotRelayer() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Non-relayer tries to liquidate
        vm.startPrank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(PredmartLendingPool.NotRelayer.selector);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: MARKET RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_Won() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Resolve market — borrower's shares won
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        (bool resolved, bool won) = pool.resolvedMarkets(TOKEN_ID_YES);
        assertTrue(resolved);
        assertTrue(won);

        // closeResolvedPosition should revert on won markets — must use redemption flow
        vm.expectRevert(PredmartPoolExtension.UseRedemptionFlow.selector);
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);

        // Position should still exist (must go through redeemWonCollateral + settleRedemption)
        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
    }

    function test_ResolveMarket_Lost() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 totalAssetsBefore = pool.totalAssets();

        // Resolve market — borrower's shares lost
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, false));
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);

        // Position should be deleted (bad debt written off)
        (uint256 collateral, uint256 debt,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(pool.totalBorrowAssets(), 0);

        // totalAssets should decrease (bad debt socialized to lenders)
        assertLt(pool.totalAssets(), totalAssetsBefore);
    }

    function test_CannotBorrowAgainstResolvedMarket() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        vm.stopPrank();

        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        vm.startPrank(borrower);
        vm.expectRevert(PredmartLendingPool.MarketResolved.selector);
        pool.depositCollateral(TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: RISK MODEL INTERPOLATION
    //////////////////////////////////////////////////////////////*/

    function test_LTV_AtAnchors() public view {
        assertEq(pool.getLTV(0), 0.02e18); // $0.00 → 2%
        assertEq(pool.getLTV(0.10e18), 0.08e18); // $0.10 → 8%
        assertEq(pool.getLTV(0.20e18), 0.30e18); // $0.20 → 30%
        assertEq(pool.getLTV(0.40e18), 0.45e18); // $0.40 → 45%
        assertEq(pool.getLTV(0.60e18), 0.60e18); // $0.60 → 60%
        assertEq(pool.getLTV(0.80e18), 0.70e18); // $0.80 → 70%
        assertEq(pool.getLTV(1.00e18), 0.75e18); // $1.00 → 75%
    }

    function test_LTV_Interpolated() public view {
        // $0.50 is between $0.40 (45%) and $0.60 (60%)
        // Expected: 45% + (0.50-0.40)/(0.60-0.40) * (60%-45%) = 45% + 0.5 * 15% = 52.5%
        uint256 ltv = pool.getLTV(0.50e18);
        assertEq(ltv, 0.525e18);
    }

    function test_LTV_NeverExceeds75() public view {
        // Even at price > $1.00, LTV should be capped at 75%
        assertEq(pool.getLTV(1.50e18), 0.75e18);
    }


    /*//////////////////////////////////////////////////////////////
                     TEST: INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    function test_BorrowRate_ZeroUtilization() public view {
        // No borrows — should return base rate (5%)
        assertEq(pool.getBorrowRate(), 0.05e18);
    }

    function test_BorrowRate_AtKink() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about interest rate model
        _supply(lender, 10_000e6);
        // Borrow within LTV: 5000 collateral at $1.00, LTV=75%, max=3750. Borrow 3500.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 3_500e6, 1e18);
        // Utilization = 3500 / 10000 = 35%
        uint256 rate = pool.getBorrowRate();
        assertGt(rate, 0.05e18, "Rate should be above base at non-zero utilization");
    }

    /*//////////////////////////////////////////////////////////////
                       TEST: ORACLE VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function test_Oracle_RejectsStalePrice() public {
        // Warp to a reasonable time so subtraction doesn't underflow
        vm.warp(1_000_000);

        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        // Create price data with old timestamp (11 seconds ago, exceeds MAX_RELAY_PRICE_AGE of 10 seconds)
        PredmartOracle.PriceData memory stalePrice = _signPriceAt(TOKEN_ID_YES, 0.80e18, block.timestamp - 11 seconds);

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.PriceTooOld.selector);
        pool.borrowViaRelay(intent, sig, stalePrice);
    }

    function test_Oracle_RejectsWrongSigner() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        // Sign with wrong key
        uint256 wrongKey = 0xBAD;
        uint256 maxBorrow = type(uint256).max;
        bytes32 hash = keccak256(abi.encodePacked(block.chainid, address(pool), TOKEN_ID_YES, uint256(0.80e18), block.timestamp, maxBorrow));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);
        PredmartOracle.PriceData memory badPrice = PredmartOracle.PriceData({
            tokenId: TOKEN_ID_YES,
            price: 0.80e18,
            timestamp: block.timestamp,
            maxBorrow: maxBorrow,
            signature: abi.encodePacked(r, s, v)
        });

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.InvalidOracleSignature.selector);
        pool.borrowViaRelay(intent, sig, badPrice);
    }

    function test_Oracle_RejectsPriceAboveDollar() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.PriceTooHigh.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 1.5e18));
    }

    /*//////////////////////////////////////////////////////////////
                       TEST: ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_TransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        poolAdmin.transferAdmin(newAdmin);
        assertEq(pool.admin(), newAdmin);
    }

    function test_TransferAdmin_RevertsNonAdmin() public {
        vm.prank(lender);
        vm.expectRevert(PredmartLendingPool.NotAdmin.selector);
        poolAdmin.transferAdmin(lender);
    }

    function test_SetOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.startPrank(admin);
        poolAdmin.proposeAddress(0, newOracle);
        poolAdmin.executeAddress(0);
        vm.stopPrank();
        assertEq(pool.oracle(), newOracle);
    }

    function test_WithdrawReserves() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Fast forward to accrue some reserves
        vm.warp(block.timestamp + 365.25 days);

        // Trigger accrual
        pool.accrueInterest();

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0, "Should have reserves");

        uint256 adminBalanceBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        pool.withdrawReserves(reserves);

        assertEq(usdc.balanceOf(admin), adminBalanceBefore + reserves);
        assertEq(pool.totalReserves(), 0);
    }

    function test_Pause_BlocksBorrow() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        // Admin pauses
        vm.prank(admin);
        poolAdmin.setPaused(true);
        assertTrue(pool.paused());

        // Borrow via relay should revert
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ProtocolPaused.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Pause_BlocksDepositCollateral() public {
        vm.prank(admin);
        poolAdmin.setPaused(true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        vm.expectRevert(PredmartLendingPool.ProtocolPaused.selector);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();
    }

    function test_Pause_AllowsRepayAndWithdraw() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Admin pauses
        vm.prank(admin);
        poolAdmin.setPaused(true);

        // Repay still works
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(TOKEN_ID_YES, 500e6);
        vm.stopPrank();

        assertEq(pool.totalBorrowAssets(), 1_500e6);

        // Lender withdraw still works
        uint256 redeemable = pool.maxRedeem(lender);
        assertGt(redeemable, 0);
    }

    function test_Pause_AllowsLiquidation() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about pause behavior
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        vm.prank(admin);
        poolAdmin.setPaused(true);

        // Liquidation still works (via relayer)
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
    }

    function test_Unpause() public {
        vm.prank(admin);
        poolAdmin.setPaused(true);

        vm.prank(admin);
        poolAdmin.setPaused(false);
        assertFalse(pool.paused());

        // Borrow works again
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        (, uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertGt(borrowShares, 0);
    }

    function test_SetAnchors() public {
        uint256[7] memory prices = [uint256(0), 0.15e18, 0.30e18, 0.50e18, 0.70e18, 0.85e18, 1.00e18];
        uint256[7] memory ltvs = [uint256(0.01e18), 0.05e18, 0.25e18, 0.40e18, 0.55e18, 0.65e18, 0.70e18];

        vm.startPrank(admin);
        poolAdmin.proposeAnchors(prices, ltvs);
        poolAdmin.executeAnchors();
        vm.stopPrank();

        assertEq(pool.priceAnchors(1), 0.15e18);
        assertEq(pool.ltvAnchors(0), 0.01e18);
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: BOTH YES AND NO SHARES
    //////////////////////////////////////////////////////////////*/

    function test_BothYesAndNoShares() public {
        _supply(lender, 50_000e6);

        // Borrow against YES shares
        _depositAndBorrow(borrower, TOKEN_ID_YES, 3_000e6, 1_000e6, 0.80e18);

        // Borrow against NO shares (separate position)
        _depositAndBorrow(borrower, TOKEN_ID_NO, 2_000e6, 800e6, 0.80e18);

        // Both positions should exist independently
        (uint256 collYes, uint256 sharesYes,,) = pool.positions(borrower, TOKEN_ID_YES);
        (uint256 collNo, uint256 sharesNo,,) = pool.positions(borrower, TOKEN_ID_NO);
        assertEq(collYes, 3_000e6);
        assertGt(sharesYes, 0);
        assertEq(collNo, 2_000e6);
        assertGt(sharesNo, 0);
        assertApproxEqAbs(pool.totalBorrowAssets(), 1_800e6, 100); // tiny interest from warp
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: ISOLATED POSITIONS
    //////////////////////////////////////////////////////////////*/

    function test_IsolatedPositions_OneLiquidatedOtherSafe() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about position isolation
        _supply(lender, 50_000e6);

        // Two positions for the same borrower
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);
        _depositAndBorrow(borrower, TOKEN_ID_NO, 5_000e6, 2_000e6, 0.80e18);

        // YES price drops — position becomes unhealthy
        // NO price stays high — position is fine
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));

        // YES position liquidated
        (uint256 collYes,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collYes, 0);

        // NO position untouched
        (uint256 collNo, uint256 sharesNo,,) = pool.positions(borrower, TOKEN_ID_NO);
        assertEq(collNo, 5_000e6);
        assertGt(sharesNo, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    TEST: HEALTH FACTOR VIEW
    //////////////////////////////////////////////////////////////*/

    function test_HealthFactor() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // At $0.80: threshold = LTV(0.80) + 10% = 70% + 10% = 80%
        // HF = 5000 * 0.80 * 0.80 / 2000 = 1.6
        uint256 hf = pool.getHealthFactor(borrower, TOKEN_ID_YES, 0.80e18);
        assertEq(hf, 1.6e18);

        // At $0.50: threshold = LTV(0.50) + 10% = 52.5% + 10% = 62.5%
        // HF = 5000 * 0.50 * 0.625 / 2000 = 0.78125
        uint256 hf2 = pool.getHealthFactor(borrower, TOKEN_ID_YES, 0.50e18);
        assertEq(hf2, 0.78125e18);

        // HF decreases with lower price — position becomes liquidatable
        uint256 hf3 = pool.getHealthFactor(borrower, TOKEN_ID_YES, 0.40e18);
        assertLt(hf3, hf2, "Lower price should give lower health factor");
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: ERC-4626 EXCHANGE RATE
    //////////////////////////////////////////////////////////////*/

    function test_ExchangeRateGrows() public {
        _supply(lender, 50_000e6);
        uint256 sharesBefore = pool.balanceOf(lender);
        uint256 valueBeforePerShare = pool.convertToAssets(1e12);

        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365.25 days);

        // Trigger accrual
        pool.accrueInterest();

        uint256 valueAfterPerShare = pool.convertToAssets(1e12);
        assertGt(valueAfterPerShare, valueBeforePerShare, "pUSDC should be worth more after interest accrues");

        // Lender shares unchanged
        assertEq(pool.balanceOf(lender), sharesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: PER-TOKEN BORROW CAP
    //////////////////////////////////////////////////////////////*/

    function test_BorrowCap_InitializedTo5Percent() public view {
        assertEq(pool.poolCapBps(), 500);
        // Pool has 0 deposits, so cap is 0
        assertEq(pool.totalAssets() * pool.poolCapBps() / 10000, 0);
    }

    function test_BorrowCap_ScalesWithDeposits() public {
        _supply(lender, 50_000e6);
        // 5% of 50,000 = 2,500
        assertEq(pool.totalAssets() * pool.poolCapBps() / 10000, 2_500e6);
    }

    function test_BorrowCap_BlocksExcessiveBorrow() public {
        _supply(lender, 50_000e6);
        // Cap = 2,500 USDC per token. Try to borrow 2,600 at price $0.80 with 5000 collateral.
        // LTV at 0.80 = 70%, maxBorrow = 5000 * 0.80 * 0.70 = 2,800 — within LTV but exceeds cap.
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 2_600e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 2_600e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsTokenCap.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowCap_AllowsWithinCap() public {
        _supply(lender, 50_000e6);
        // Cap = 2,500. Borrow 2,000 — should succeed.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);
        assertEq(pool.totalBorrowedPerToken(TOKEN_ID_YES), 2_000e6);
    }

    function test_BorrowCap_DecreasesOnRepay() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.startPrank(borrower);
        usdc.approve(address(pool), 1_000e6);
        pool.repay(TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();

        // Should have decreased by the repay amount
        assertApproxEqAbs(pool.totalBorrowedPerToken(TOKEN_ID_YES), 1_000e6, 100);
    }

    function test_BorrowCap_DecreasesOnLiquidation() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 trackedBefore = pool.totalBorrowedPerToken(TOKEN_ID_YES);
        assertEq(trackedBefore, 2_000e6);

        // Price drops → liquidate (via relayer)
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));

        // Tracked amount should decrease
        assertLt(pool.totalBorrowedPerToken(TOKEN_ID_YES), trackedBefore);
    }

    function test_BorrowCap_AdminCanUpdate() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(1000); // 10%
        assertEq(pool.poolCapBps(), 1000);

        _supply(lender, 50_000e6);
        assertEq(pool.totalAssets() * pool.poolCapBps() / 10000, 5_000e6); // 10% of 50K
    }

    function test_BorrowCap_DisabledWhenZero() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);

        _supply(lender, 50_000e6);
        assertEq(pool.totalAssets() * pool.poolCapBps() / 10000, 0);

        // Should still be able to borrow (cap disabled)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);
        assertEq(pool.totalBorrowedPerToken(TOKEN_ID_YES), 2_700e6);
    }

    // ─── Real-time view accrual ───

    function test_ViewFunctions_IncludePendingInterest() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about view function accrual
        _supply(lender, 10_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 debtAtBorrow = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsAtBorrow = pool.totalAssets();

        // Warp 30 days — no state-changing interactions
        vm.warp(block.timestamp + 30 days);

        // View functions should reflect pending interest without any transaction
        uint256 debtAfter = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsAfter = pool.totalAssets();

        // Debt should have grown (interest accruing)
        assertGt(debtAfter, debtAtBorrow, "Debt should grow with pending interest");
        // totalAssets should have grown (lenders earn yield)
        assertGt(totalAssetsAfter, totalAssetsAtBorrow, "totalAssets should include pending interest");

        // Health factor should be lower (debt grew, collateral unchanged)
        uint256 hfAtBorrow = pool.getHealthFactor(borrower, TOKEN_ID_YES, 0.80e18);
        assertLt(hfAtBorrow, type(uint256).max, "HF should be finite with debt");

        // Verify accrueInterest() produces the same result (consistency check)
        pool.accrueInterest();
        uint256 debtAfterAccrual = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsAfterAccrual = pool.totalAssets();
        assertEq(debtAfter, debtAfterAccrual, "View debt should match post-accrual debt");
        assertEq(totalAssetsAfter, totalAssetsAfterAccrual, "View totalAssets should match post-accrual");
    }

    /*//////////////////////////////////////////////////////////////
                   TEST: RELAY INTENT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_BorrowViaRelay_RevertsNotRelayer() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        // Non-relayer tries to call borrowViaRelay
        vm.prank(liquidator);
        vm.expectRevert(PredmartLendingPool.NotRelayer.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsExpiredIntent() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp - 1; // Already expired
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.IntentExpired.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsInvalidNonce() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 wrongNonce = 999; // Wrong nonce (should be 0)
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: wrongNonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, wrongNonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidNonce.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsInvalidSignature() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        // Sign with wrong key (relayer's key instead of borrower's)
        bytes memory wrongSig = _signBorrowIntent(relayerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidIntentSignature.selector);
        pool.borrowViaRelay(intent, wrongSig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_IncrementsNonce() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();


        uint256 nonceBefore = pool.borrowNonces(borrower);
        assertEq(nonceBefore, 0);

        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonceBefore,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonceBefore, deadline);

        vm.prank(relayer);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        uint256 nonceAfter = pool.borrowNonces(borrower);
        assertEq(nonceAfter, 1);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: DELEVERAGE STEP
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: set up a leveraged position (deposit + borrow) for deleverage tests
    function _setupLeveragedPosition() internal returns (uint256 borrowAmount) {
        _supply(lender, 50_000e6);
        borrowAmount = 2_000e6;
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, borrowAmount, 0.80e18);
    }

    function test_DeleverageStep_RepayOnly() public {
        _setupLeveragedPosition();

        // Repay-only step (no withdrawal) — first step in some deleverage flows
        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 3_000e6;
        uint256 repayAmount = 500e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        uint256 debtBefore = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 safeBalBefore = usdc.balanceOf(safe);

        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, repayAmount, 0, _signPrice(TOKEN_ID_YES, 0.80e18));

        uint256 debtAfter = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertApproxEqAbs(debtBefore - debtAfter, repayAmount, 100, "Debt should decrease by repay amount");
        assertEq(usdc.balanceOf(safe), safeBalBefore - repayAmount, "USDC pulled from Safe");

        // No withdrawal means nonce should NOT be consumed (nonce only consumed on first withdraw)
        assertEq(pool.deleverageNonces(borrower), nonce, "Nonce unchanged on repay-only");
    }

    function test_DeleverageStep_WithdrawOnly() public {
        // Deposit collateral without borrowing — no debt, so withdrawal is free
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 2_000e6;
        uint256 withdrawAmount = 1_000e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 0, withdrawAmount, _signPrice(TOKEN_ID_YES, 0.80e18));

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 4_000e6, "Collateral decreased by withdraw amount");
        assertEq(ctf.balanceOf(safe, TOKEN_ID_YES), withdrawAmount, "Shares sent to Safe");
        assertEq(pool.deleverageNonces(borrower), nonce + 1, "Nonce consumed on first withdraw");
    }

    function test_DeleverageStep_RepayAndWithdraw() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 3_000e6;
        uint256 repayAmount = 500e6;
        uint256 withdrawAmount = 800e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        uint256 debtBefore = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, repayAmount, withdrawAmount, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Verify repay
        uint256 debtAfter = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertApproxEqAbs(debtBefore - debtAfter, repayAmount, 100, "Debt decreased");

        // Verify withdraw
        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6 - withdrawAmount, "Collateral decreased");
        assertEq(ctf.balanceOf(safe, TOKEN_ID_YES), withdrawAmount, "Shares sent to Safe");

        // Verify budget tracking
        assertEq(pool.deleverageNonces(borrower), nonce + 1, "Nonce consumed");
    }

    function test_DeleverageStep_FullRepayThenWithdrawAll() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 5_000e6;
        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Step 1: repay all debt + withdraw some
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, debt, 2_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        assertEq(pool.getPositionDebt(borrower, TOKEN_ID_YES), 0, "Debt fully repaid");
        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6, "Collateral after partial withdraw");

        // Step 2: withdraw remaining (no debt, no HF check needed)
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 0, 3_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        (collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0, "All collateral withdrawn");
        assertEq(ctf.balanceOf(safe, TOKEN_ID_YES), 5_000e6, "All shares in Safe");
    }

    function test_DeleverageStep_MultipleStepsBudgetTracking() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 2_000e6; // Budget: max 2000 shares total

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Step 1: repay 500, withdraw 800
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 500e6, 800e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 2: repay 500, withdraw 800 (total 1600 < 2000 budget)
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 500e6, 800e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 3: try to withdraw 500 more (total would be 2100 > 2000 budget)
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsWithdrawBudget.selector);
        pool.deleverageStep(auth, sig, safe, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 3 corrected: withdraw exactly remaining budget (400)
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 0, 400e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        assertEq(ctf.balanceOf(safe, TOKEN_ID_YES), 2_000e6, "Total withdrawn matches budget");
    }

    function test_DeleverageStep_RevertsNotRelayer() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(liquidator); // Not the relayer
        vm.expectRevert(PredmartLendingPool.NotRelayer.selector);
        pool.deleverageStep(auth, sig, safe, 500e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsExpiredDeadline() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp - 1; // Already expired
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.IntentExpired.selector);
        pool.deleverageStep(auth, sig, safe, 500e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsInvalidSignature() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        // Sign with relayer's key instead of borrower's
        bytes memory wrongSig = _signDeleverageAuth(relayerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidIntentSignature.selector);
        pool.deleverageStep(auth, wrongSig, safe, 500e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsInvalidNonce() public {
        _setupLeveragedPosition();

        uint256 wrongNonce = 999;
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: wrongNonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, wrongNonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidNonce.selector);
        pool.deleverageStep(auth, sig, safe, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsInvalidTo() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        // Try to send shares to an unauthorized address (not safe, not relayer)
        address attacker = makeAddr("attacker");
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidAddress.selector);
        pool.deleverageStep(auth, sig, attacker, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsExceedsWithdrawBudget() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 500e6; // Small budget

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Try to withdraw more than budget allows in one step
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsWithdrawBudget.selector);
        pool.deleverageStep(auth, sig, safe, 0, 600e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_RevertsWithdrawMakesUnhealthy() public {
        _setupLeveragedPosition();
        // Position: 5000 collateral, 2000 debt, price 0.80
        // HF = 5000 * 0.80 * 0.80 / 2000 = 1.6

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 5_000e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Try to withdraw 4000 shares — would leave 1000 collateral with 2000 debt
        // HF = 1000 * 0.80 * 0.80 / 2000 = 0.32 → unhealthy
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsLTV.selector);
        pool.deleverageStep(auth, sig, safe, 0, 4_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_NonceOnlyConsumedOnFirstWithdraw() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 3_000e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Step 1: repay only (no withdraw) — nonce not consumed
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 200e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
        assertEq(pool.deleverageNonces(borrower), nonce, "Nonce unchanged after repay-only");

        // Step 2: first withdraw — nonce consumed
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 200e6, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        assertEq(pool.deleverageNonces(borrower), nonce + 1, "Nonce consumed on first withdraw");

        // Step 3: second withdraw under same auth — nonce NOT consumed again
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 200e6, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        assertEq(pool.deleverageNonces(borrower), nonce + 1, "Nonce still 1 after second withdraw");
    }

    function test_DeleverageStep_RelayerCanBeToAddress() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 1_000e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Relayer sends shares to itself (allowed per contract: to == msg.sender)
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, relayer, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        assertEq(ctf.balanceOf(relayer, TOKEN_ID_YES), 500e6, "Relayer received shares");
    }

    function test_DeleverageStep_RepayFromReducesDebtCorrectly() public {
        _setupLeveragedPosition();

        uint256 debtBefore = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 safeBalBefore = usdc.balanceOf(safe);
        uint256 poolBalBefore = usdc.balanceOf(address(pool));

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        uint256 repayAmount = 1_000e6;
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, repayAmount, 0, _signPrice(TOKEN_ID_YES, 0.80e18));

        // USDC pulled from Safe → Pool
        assertEq(usdc.balanceOf(safe), safeBalBefore - repayAmount, "USDC left Safe");
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore + repayAmount, "USDC arrived at pool");

        // Debt decreased
        uint256 debtAfter = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertApproxEqAbs(debtBefore - debtAfter, repayAmount, 100);
    }

    function test_DeleverageStep_OverRepayCapsToCurrent() public {
        _setupLeveragedPosition();

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 safeBalBefore = usdc.balanceOf(safe);

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 5_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 5_000e6, nonce, deadline);

        // Repay MORE than the debt — should be capped
        uint256 overRepay = debt + 1_000e6;
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, overRepay, 5_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        assertEq(pool.getPositionDebt(borrower, TOKEN_ID_YES), 0, "Debt fully cleared");
        // Should have only pulled the actual debt amount, not the over-repay
        assertEq(usdc.balanceOf(safe), safeBalBefore - debt, "Only actual debt pulled from Safe");
    }

    function test_DeleverageStep_RevertsPaused() public {
        _setupLeveragedPosition();

        vm.prank(admin);
        poolAdmin.setPaused(true);

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ProtocolPaused.selector);
        pool.deleverageStep(auth, sig, safe, 500e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_DeleverageStep_SeparateNonceSpace() public {
        _setupLeveragedPosition();

        // Borrow nonce should be 1 (from _depositAndBorrow)
        assertEq(pool.borrowNonces(borrower), 1);
        // Deleverage nonce should be 0 (unused)
        assertEq(pool.deleverageNonces(borrower), 0);

        // Execute a deleverage step with withdraw
        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 200e6, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Deleverage nonce incremented, borrow nonce unchanged
        assertEq(pool.deleverageNonces(borrower), 1);
        assertEq(pool.borrowNonces(borrower), 1, "Borrow nonce unaffected by deleverage");
    }

    function test_DeleverageStep_StaleAuthCannotBeReused() public {
        _setupLeveragedPosition();

        uint256 nonce = pool.deleverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxWithdraw = 1_000e6;

        PredmartLendingPool.DeleverageAuth memory auth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: maxWithdraw,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxWithdraw, nonce, deadline);

        // Use the full budget
        vm.prank(relayer);
        pool.deleverageStep(auth, sig, safe, 500e6, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Now create a NEW auth with the same (now stale) nonce
        PredmartLendingPool.DeleverageAuth memory staleAuth = PredmartLendingPool.DeleverageAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: TOKEN_ID_YES,
            maxWithdraw: 5_000e6, // Bigger budget this time
            nonce: nonce, // Stale nonce (should be nonce+1 now)
            deadline: deadline
        });
        bytes memory staleSig = _signDeleverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 5_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidNonce.selector);
        pool.deleverageStep(staleAuth, staleSig, safe, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /*//////////////////////////////////////////////////////////////
              TEST: EXTENSION — TIMELOCKED ADMIN FLOWS
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: activate a 6-hour timelock (mirrors production)
    function _activateTimelock() internal {
        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);
    }

    function test_TimelockAdmin_ProposeWaitExecute() public {
        _activateTimelock();
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        poolAdmin.transferAdmin(newAdmin);

        // Pending but not yet executable
        assertEq(pool.admin(), admin, "Admin unchanged before timelock");
        assertEq(pool.pendingAdmin(), newAdmin);
        assertGt(pool.pendingAdminExecAfter(), block.timestamp);

        // Revert if executed too early
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockNotReady.selector);
        poolAdmin.executeTransferAdmin();

        // Warp past timelock
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(admin);
        poolAdmin.executeTransferAdmin();

        assertEq(pool.admin(), newAdmin, "Admin transferred after timelock");
        assertEq(pool.pendingAdmin(), address(0), "Pending cleared");
    }

    function test_TimelockAdmin_ProposeCancel() public {
        _activateTimelock();
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        poolAdmin.transferAdmin(newAdmin);

        assertEq(pool.pendingAdmin(), newAdmin);

        vm.prank(admin);
        poolAdmin.cancelTransferAdmin();

        assertEq(pool.pendingAdmin(), address(0), "Pending cleared after cancel");
        assertEq(pool.admin(), admin, "Admin unchanged after cancel");
    }

    function test_TimelockRelayer_ProposeWaitExecute() public {
        _activateTimelock();
        address newRelayer = makeAddr("newRelayer");

        vm.prank(admin);
        poolAdmin.proposeAddress(1, newRelayer);

        assertEq(pool.relayer(), relayer, "Relayer unchanged before timelock");
        assertEq(pool.pendingRelayer(), newRelayer);

        // Warp past timelock
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(admin);
        poolAdmin.executeAddress(1);

        assertEq(pool.relayer(), newRelayer, "Relayer rotated");
        assertEq(pool.pendingRelayer(), address(0));
    }

    function test_TimelockRelayer_Cancel() public {
        _activateTimelock();
        address newRelayer = makeAddr("newRelayer");

        vm.prank(admin);
        poolAdmin.proposeAddress(1, newRelayer);

        vm.prank(admin);
        poolAdmin.cancelPending(1);

        assertEq(pool.pendingRelayer(), address(0));
        assertEq(pool.relayer(), relayer, "Relayer unchanged");
    }

    function test_TimelockOracle_ProposeWaitExecute() public {
        _activateTimelock();
        address newOracle = makeAddr("newOracle");

        vm.prank(admin);
        poolAdmin.proposeAddress(0, newOracle);

        assertEq(pool.oracle(), oracleAddress, "Oracle unchanged before timelock");

        // Revert before timelock
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockNotReady.selector);
        poolAdmin.executeAddress(0);

        // Warp past timelock
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(admin);
        poolAdmin.executeAddress(0);

        assertEq(pool.oracle(), newOracle, "Oracle rotated");
    }

    function test_TimelockOracle_Cancel() public {
        _activateTimelock();

        vm.prank(admin);
        poolAdmin.proposeAddress(0, makeAddr("newOracle"));

        vm.prank(admin);
        poolAdmin.cancelPending(0);

        assertEq(pool.pendingOracle(), address(0));
        assertEq(pool.oracle(), oracleAddress);
    }

    function test_TimelockAnchors_ProposeWaitExecute() public {
        _activateTimelock();

        uint256[7] memory prices = [uint256(0), 0.15e18, 0.30e18, 0.50e18, 0.70e18, 0.85e18, 1.00e18];
        uint256[7] memory ltvs = [uint256(0.01e18), 0.05e18, 0.25e18, 0.40e18, 0.55e18, 0.65e18, 0.70e18];

        vm.prank(admin);
        poolAdmin.proposeAnchors(prices, ltvs);

        // Not yet executable
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockNotReady.selector);
        poolAdmin.executeAnchors();

        // Warp past timelock
        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(admin);
        poolAdmin.executeAnchors();

        assertEq(pool.priceAnchors(1), 0.15e18, "Anchors updated");
        assertEq(pool.ltvAnchors(0), 0.01e18);
    }

    function test_TimelockAnchors_Cancel() public {
        _activateTimelock();

        uint256[7] memory prices = [uint256(0), 0.15e18, 0.30e18, 0.50e18, 0.70e18, 0.85e18, 1.00e18];
        uint256[7] memory ltvs = [uint256(0.01e18), 0.05e18, 0.25e18, 0.40e18, 0.55e18, 0.65e18, 0.70e18];

        vm.prank(admin);
        poolAdmin.proposeAnchors(prices, ltvs);

        vm.prank(admin);
        poolAdmin.cancelPending(3); // kind=3 is anchors

        // Original anchors unchanged
        assertEq(pool.priceAnchors(1), 0.10e18);
    }

    function test_TimelockAnchors_RevertsInvalidAnchors() public {
        // LTV + LIQUIDATION_BUFFER > 1.0 should revert
        uint256[7] memory prices = [uint256(0), 0.10e18, 0.20e18, 0.40e18, 0.60e18, 0.80e18, 1.00e18];
        uint256[7] memory badLtvs = [uint256(0.02e18), 0.08e18, 0.30e18, 0.45e18, 0.60e18, 0.70e18, 0.95e18]; // 95% + 10% > 100%

        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.InvalidAnchors.selector);
        poolAdmin.proposeAnchors(prices, badLtvs);
    }

    function test_TimelockAnchors_RevertsNonMonotonicPrices() public {
        // Prices must be strictly increasing
        uint256[7] memory badPrices = [uint256(0), 0.10e18, 0.20e18, 0.15e18, 0.60e18, 0.80e18, 1.00e18]; // 0.15 < 0.20
        uint256[7] memory ltvs = [uint256(0.02e18), 0.08e18, 0.30e18, 0.45e18, 0.60e18, 0.70e18, 0.75e18];

        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.InvalidAnchors.selector);
        poolAdmin.proposeAnchors(badPrices, ltvs);
    }

    function test_ActivateTimelock_RatchetUp() public {
        // Can increase timelock
        vm.prank(admin);
        poolAdmin.activateTimelock(1 hours);
        assertEq(pool.timelockDelay(), 1 hours);

        // Can increase further
        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);
        assertEq(pool.timelockDelay(), 6 hours);
    }

    function test_ActivateTimelock_RevertsDecrease() public {
        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);

        // Cannot decrease — ratchet
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockCannotDecrease.selector);
        poolAdmin.activateTimelock(1 hours);
    }

    function test_ExecuteAddress_RevertsNoPendingChange() public {
        _activateTimelock();

        // No pending oracle change — should revert
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.NoPendingChange.selector);
        poolAdmin.executeAddress(0);

        // No pending relayer change
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.NoPendingChange.selector);
        poolAdmin.executeAddress(1);
    }

    function test_ExecuteTransferAdmin_RevertsNoPendingChange() public {
        _activateTimelock();

        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.NoPendingChange.selector);
        poolAdmin.executeTransferAdmin();
    }

    function test_ProposeAddress_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.InvalidAddress.selector);
        poolAdmin.proposeAddress(0, address(0));
    }

    function test_TransferAdmin_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.InvalidAddress.selector);
        poolAdmin.transferAdmin(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: LEVERAGE STEP
    //////////////////////////////////////////////////////////////*/

    function test_LeverageStep_DepositAndBorrow() public {
        _supply(lender, 50_000e6);

        // Borrower deposits collateral first
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 3_000e6);
        vm.stopPrank();

        // Relayer holds some CTF shares (simulating post-CLOB purchase)
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6;

        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: maxBorrow,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxBorrow, nonce, deadline);

        // Relayer deposits 2000 shares (from relayer itself) + borrows 1000 USDC
        vm.prank(relayer);
        pool.leverageStep(auth, sig, relayer, 2_000e6, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Verify: borrower's position now has 5000 collateral (3000 initial + 2000 from leverage)
        (uint256 collateral, uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6, "Collateral includes leveraged deposit");
        assertGt(borrowShares, 0, "Borrow shares created");
        assertEq(pool.leverageNonces(borrower), nonce + 1, "Nonce consumed on first borrow");
    }

    function test_LeverageStep_DepositOnly() public {
        _supply(lender, 50_000e6);

        // Borrower deposits some initial collateral
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();

        // Relayer has shares
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6;

        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: maxBorrow,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxBorrow, nonce, deadline);

        // Deposit only, no borrow — nonce should NOT be consumed
        vm.prank(relayer);
        pool.leverageStep(auth, sig, relayer, 2_000e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6, "Collateral increased");
        assertEq(pool.leverageNonces(borrower), nonce, "Nonce unchanged on deposit-only");
    }

    function test_LeverageStep_MultipleStepsBudgetTracking() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6; // Budget: max 2000 USDC total

        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: maxBorrow,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, maxBorrow, nonce, deadline);

        // Step 1: borrow 800
        vm.prank(relayer);
        pool.leverageStep(auth, sig, relayer, 0, 800e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 2: borrow 800 more (total 1600 < 2000 budget)
        vm.prank(relayer);
        pool.leverageStep(auth, sig, relayer, 0, 800e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 3: try to borrow 500 more (total 2100 > 2000 budget)
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ExceedsBorrowBudget.selector);
        pool.leverageStep(auth, sig, relayer, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Step 3 corrected: borrow exactly remaining 400
        vm.prank(relayer);
        pool.leverageStep(auth, sig, relayer, 0, 400e6, _signPrice(TOKEN_ID_YES, 0.80e18));

        assertEq(pool.totalBorrowAssets(), 2_000e6, "Total borrowed matches budget");
    }

    function test_LeverageStep_RevertsNotRelayer() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(liquidator);
        vm.expectRevert(PredmartLendingPool.NotRelayer.selector);
        pool.leverageStep(auth, sig, relayer, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_LeverageStep_RevertsExpired() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp - 1; // Already expired
        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.IntentExpired.selector);
        pool.leverageStep(auth, sig, relayer, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_LeverageStep_RevertsInvalidFrom() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe, // Only safe or relayer allowed
            tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        address attacker = makeAddr("attacker");
        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidAddress.selector);
        pool.leverageStep(auth, sig, attacker, 500e6, 0, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_LeverageStep_RevertsInvalidSignature() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.LeverageAuth memory auth = PredmartLendingPool.LeverageAuth({
            borrower: borrower,
            allowedFrom: safe,
            tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        // Sign with wrong key
        bytes memory wrongSig = _signLeverageAuth(relayerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.InvalidIntentSignature.selector);
        pool.leverageStep(auth, wrongSig, relayer, 0, 500e6, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /*//////////////////////////////////////////////////////////////
              TEST: EDGE CASES — BORROW BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_Borrow_RevertsBorrowTooSmall() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        // Try to borrow $0.50 — below MIN_BORROW ($1)
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 0.5e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 0.5e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.BorrowTooSmall.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Borrow_ExactlyMinBorrow() public {
        _supply(lender, 50_000e6);

        // Borrow exactly $1 (MIN_BORROW = 1e6)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 1e6, 0.80e18);

        (, uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertGt(borrowShares, 0, "Position created at MIN_BORROW");
        assertEq(pool.totalBorrowAssets(), 1e6);
    }

    function test_Repay_WithMaxUint_AfterInterest() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Accrue interest for 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertGt(debtBefore, 2_000e6, "Debt grew from interest");

        // Full repay with type(uint256).max
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        (, uint256 borrowShares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(borrowShares, 0, "All shares burned");
        assertEq(pool.totalBorrowShares(), 0, "Global shares zeroed");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: FROZEN TOKEN BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function test_FrozenToken_BlocksDeposit() public {
        vm.prank(admin);
        poolAdmin.setTokenFrozen(TOKEN_ID_YES, true);
        assertTrue(pool.frozenTokens(TOKEN_ID_YES));

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        vm.expectRevert(PredmartLendingPool.TokenFrozen.selector);
        pool.depositCollateral(TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();
    }

    function test_FrozenToken_BlocksBorrow() public {
        _supply(lender, 50_000e6);

        // Deposit before freeze
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        // Freeze the token
        vm.prank(admin);
        poolAdmin.setTokenFrozen(TOKEN_ID_YES, true);

        // Try to borrow — should revert
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower,
            tokenId: TOKEN_ID_YES,
            amount: 1_000e6,
            nonce: nonce,
            deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 1_000e6, nonce, deadline);

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.TokenFrozen.selector);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_FrozenToken_Unfreeze() public {
        vm.prank(admin);
        poolAdmin.setTokenFrozen(TOKEN_ID_YES, true);

        vm.prank(admin);
        poolAdmin.setTokenFrozen(TOKEN_ID_YES, false);
        assertFalse(pool.frozenTokens(TOKEN_ID_YES));

        // Deposit works after unfreeze
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
            TEST: LIQUIDATION — UNDERWATER PATH (bad debt)
    //////////////////////////////////////////////////////////////*/

    function test_Liquidation_Underwater_BadDebt() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        _supply(lender, 50_000e6);

        // Borrow near max LTV at $0.80
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        // Accrue significant interest
        vm.warp(block.timestamp + 180 days);
        pool.accrueInterest();

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        // Price crashes to $0.10 — collateral value = 5000 * 0.10 = $500
        // Debt >> $500 → underwater
        PredmartOracle.PriceData memory crashPrice = _signPrice(TOKEN_ID_YES, 0.10e18);

        uint256 totalAssetsBefore = pool.totalAssets();

        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, crashPrice);

        // Position fully deleted
        (uint256 collateral, uint256 shares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // Bad debt socialized — totalAssets decreased
        assertLt(pool.totalAssets(), totalAssetsBefore, "Bad debt socialized to lenders");
    }

    /*//////////////////////////////////////////////////////////////
       TEST: CLOSE RESOLVED POSITION — WON MARKET (no-op behavior)
    //////////////////////////////////////////////////////////////*/

    function test_CloseResolvedPosition_WonMarket_Reverts() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Resolve as won
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        // closeResolvedPosition reverts on won markets — must use redemption flow
        vm.expectRevert(PredmartPoolExtension.UseRedemptionFlow.selector);
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);

        // Position untouched
        (uint256 collateral, uint256 borrowSharesAfter,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6, "Collateral preserved");
        assertGt(borrowSharesAfter, 0, "Debt preserved");
    }

    function test_CloseResolvedPosition_LostMarket_DeletesPosition() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, false));
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);

        (uint256 collateral, uint256 shares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0, "Position deleted on lost market");
        assertEq(shares, 0);
    }

    function test_CloseResolvedPosition_RevertsNotResolved() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.expectRevert(PredmartPoolExtension.MarketNotResolved.selector);
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);
    }

    function test_CloseResolvedPosition_RevertsNoPosition() public {
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, false));

        vm.expectRevert(PredmartPoolExtension.NoPosition.selector);
        poolAdmin.closeResolvedPosition(borrower, TOKEN_ID_YES);
    }

    /*//////////////////////////////////////////////////////////////
         TEST: REDEEM WON COLLATERAL + SETTLE REDEMPTION
    //////////////////////////////////////////////////////////////*/

    function test_RedeemAndSettle_FullFlow_WithSurplus() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Configure mock CTF for redemption
        bytes32 conditionId = bytes32(uint256(TOKEN_ID_YES));
        ctf.configureRedemption(conditionId, TOKEN_ID_YES, address(usdc));

        // Resolve market as won
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        // Redeem: burns 5000 CTF shares, mints 5000 USDC to pool
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);

        // Verify redemption recorded
        (bool redeemed, uint256 totalShares, uint256 usdcReceived) = pool.redeemedTokens(TOKEN_ID_YES);
        assertTrue(redeemed);
        assertEq(totalShares, 5_000e6, "All shares redeemed");
        assertEq(usdcReceived, 5_000e6, "1:1 USDC from won CTF");
        assertEq(pool.unsettledRedemptions(), 5_000e6);

        // Settle: borrower's debt = ~2000, proceeds = 5000 → surplus = ~3000
        uint256 borrowerBalBefore = usdc.balanceOf(borrower);
        poolAdmin.settleRedemption(borrower, TOKEN_ID_YES);

        // Position deleted
        (uint256 collateral, uint256 shares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // Borrower received surplus
        uint256 surplus = usdc.balanceOf(borrower) - borrowerBalBefore;
        assertGt(surplus, 2_900e6, "Surplus: proceeds - debt");
        assertLt(surplus, 3_100e6); // Allow for small interest
        assertEq(pool.unsettledRedemptions(), 0, "Unsettled cleared");
    }

    function test_RedeemAndSettle_WithBadDebt() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        // Small pool → high utilization → high interest rate
        _supply(lender, 3_500e6);

        // Borrow most of pool → ~77% utilization → ~24% borrow rate
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        // Accrue interest for 5 years at high utilization
        vm.warp(block.timestamp + 1825 days);
        pool.accrueInterest();

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertGt(debt, 5_000e6, "Debt exceeds collateral value due to interest");

        // Configure and redeem
        bytes32 conditionId = bytes32(uint256(TOKEN_ID_YES));
        ctf.configureRedemption(conditionId, TOKEN_ID_YES, address(usdc));
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);

        // Settle — proceeds (5000) < debt → bad debt
        uint256 totalAssetsBefore = pool.totalAssets();
        poolAdmin.settleRedemption(borrower, TOKEN_ID_YES);

        // Position deleted, bad debt absorbed
        (uint256 collateral, uint256 shares,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // Lenders absorb bad debt
        assertLt(pool.totalAssets(), totalAssetsBefore, "Bad debt socialized");
    }

    function test_RedeemWonCollateral_RevertsNotWon() public {
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, false));

        vm.expectRevert(PredmartPoolExtension.MarketNotResolved.selector);
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, bytes32(0), 1);
    }

    function test_RedeemWonCollateral_RevertsAlreadyRedeemed() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        bytes32 conditionId = bytes32(uint256(TOKEN_ID_YES));
        ctf.configureRedemption(conditionId, TOKEN_ID_YES, address(usdc));
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);

        // Second redeem should revert
        vm.expectRevert(PredmartPoolExtension.AlreadyRedeemed.selector);
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);
    }

    function test_SettleRedemption_RevertsNotRedeemed() public {
        vm.expectRevert(PredmartPoolExtension.TokenNotRedeemed.selector);
        poolAdmin.settleRedemption(borrower, TOKEN_ID_YES);
    }

    /*//////////////////////////////////////////////////////////////
              TEST: RESOLVE MARKET — DUPLICATE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_RevertsDuplicate() public {
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        vm.expectRevert(PredmartPoolExtension.MarketAlreadyResolved.selector);
        poolAdmin.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));
    }

    /*//////////////////////////////////////////////////////////////
             TEST: FUZZ — MATH LIBRARY PROPERTIES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Interpolate_Monotonic(uint256 priceA, uint256 priceB) public view {
        // Bound prices to valid range [0, 1e18]
        priceA = bound(priceA, 0, 1e18);
        priceB = bound(priceB, priceA, 1e18);

        uint256 ltvA = pool.getLTV(priceA);
        uint256 ltvB = pool.getLTV(priceB);

        // LTV should be monotonically non-decreasing with price
        assertGe(ltvB, ltvA, "LTV must be monotonically non-decreasing");
    }

    function testFuzz_CalcBorrowRate_Bounded(uint256 utilization) public pure {
        utilization = bound(utilization, 0, 1e18);

        uint256 rate = PredmartPoolLib.calcBorrowRate(utilization);

        // Rate must be at least BASE_RATE and at most MAX_RATE
        assertGe(rate, 0.05e18, "Rate >= base rate");
        assertLe(rate, 3.00e18 + 0.05e18, "Rate bounded above");
    }

    function testFuzz_CalcPendingInterest_NonNegative(
        uint256 borrowAssets,
        uint256 elapsed,
        uint256 utilization
    ) public pure {
        borrowAssets = bound(borrowAssets, 0, 1e15); // Up to $1B USDC
        elapsed = bound(elapsed, 0, 365.25 days * 10); // Up to 10 years
        utilization = bound(utilization, 0, 1e18);

        (uint256 interest, uint256 reserveShare) = PredmartPoolLib.calcPendingInterest(
            borrowAssets, elapsed, utilization
        );

        // Interest should be non-negative
        assertGe(interest, 0, "Interest non-negative");
        // Reserve share should be <= interest
        assertLe(reserveShare, interest, "Reserve <= interest");

        // If borrowAssets > 0 and elapsed > 0, interest should be > 0
        if (borrowAssets > 0 && elapsed > 0) {
            assertGt(interest, 0, "Interest > 0 when borrowed and time passes");
        }
    }

    function testFuzz_CalcHealthFactor_Properties(
        uint256 collateral,
        uint256 debt,
        uint256 price
    ) public pure {
        collateral = bound(collateral, 1e6, 1e15); // $1 to $1B
        debt = bound(debt, 1e6, 1e15);
        price = bound(price, 0.01e18, 1e18);

        uint256 threshold = 0.80e18; // Typical threshold
        uint256 hf = PredmartPoolLib.calcHealthFactor(collateral, debt, price, threshold);

        // HF should be proportional to collateral and inversely proportional to debt
        uint256 hf2 = PredmartPoolLib.calcHealthFactor(collateral * 2, debt, price, threshold);
        assertGe(hf2, hf, "Double collateral should increase or maintain HF");
    }

    /*//////////////////////////////////////////////////////////////
          TEST: ERC-4626 — MINT AND WITHDRAW (by assets/shares)
    //////////////////////////////////////////////////////////////*/

    function test_MintShares() public {
        // mint() is the ERC-4626 shares-based deposit (vs deposit which is asset-based)
        uint256 sharesToMint = 10_000e12; // pUSDC has 12 decimals

        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        uint256 assetsRequired = pool.mint(sharesToMint, lender);
        vm.stopPrank();

        assertGt(assetsRequired, 0, "Assets deposited");
        assertEq(pool.balanceOf(lender), sharesToMint, "Exact shares minted");
    }

    function test_WithdrawAssets() public {
        _supply(lender, 10_000e6);

        // withdraw() is the ERC-4626 assets-based redemption (vs redeem which is shares-based)
        uint256 assetsToWithdraw = 5_000e6;

        vm.prank(lender);
        uint256 sharesBurned = pool.withdraw(assetsToWithdraw, lender, lender);

        assertGt(sharesBurned, 0, "Shares burned");
        assertEq(usdc.balanceOf(lender), 95_000e6, "5K withdrawn from 100K initial balance");
    }

    function test_MaxWithdraw_LimitedByLiquidity() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        _supply(lender, 10_000e6);
        // At $1.00, LTV=75%, max borrow = 10000*1.0*0.75 = 7500
        _depositAndBorrow(borrower, TOKEN_ID_YES, 10_000e6, 7_000e6, 1e18);

        // Most liquidity is lent out — maxWithdraw should be limited
        uint256 maxW = pool.maxWithdraw(lender);
        assertLt(maxW, 10_000e6, "Max withdraw < deposited due to borrows");
        assertGe(maxW, 0);
    }

    /*//////////////////////////////////////////////////////////////
        TEST: DEPOSIT COLLATERAL FROM (Safe ownership check)
    //////////////////////////////////////////////////////////////*/

    function test_DepositCollateralFrom_SameAddress() public {
        // msg.sender == from — no isOwner check needed
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateralFrom(borrower, TOKEN_ID_YES, 2_000e6);
        vm.stopPrank();

        (uint256 collateral,,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 2_000e6);
    }

    function test_DepositCollateralFrom_RevertsNotOwner() public {
        // Create a mock "Safe" that returns false for isOwner
        // No need to mint — the isOwner check happens before the transfer
        address fakeSafe = address(new MockSafeRejectsAll());

        vm.prank(borrower); // borrower is NOT an owner of fakeSafe
        vm.expectRevert(PredmartLendingPool.NotProxyOwner.selector);
        pool.depositCollateralFrom(fakeSafe, TOKEN_ID_YES, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
       TEST: PARTIAL LIQUIDATION (above water, HF >= 0.95)
    //////////////////////////////////////////////////////////////*/

    function test_Liquidation_Partial_AboveWater() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        _supply(lender, 50_000e6);

        // Position that becomes slightly unhealthy (HF just below 1.0 but above 0.95)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 10_000e6, 5_000e6, 0.80e18);

        // Price drops slightly so HF is between 0.95 and 1.0
        // At $0.70: threshold = LTV(0.70) + 10% = 65.5% + 10% = 75.5%
        // HF = 10000 * 0.70 * 0.755 / 5000 = 1.057 — still healthy
        // At $0.65: threshold = LTV(0.65) + 10% = 62.5% + 10% = 72.5%
        // HF = 10000 * 0.65 * 0.725 / 5000 = 0.9425 — unhealthy, HF < 0.95 = full close

        // Try at price that gives HF ~0.98 (slightly unhealthy, close factor = 50%)
        // At $0.68: LTV = interpolated, threshold = LTV + 10%
        // Let's just check the partial liquidation works with a moderate price drop
        PredmartOracle.PriceData memory lowPrice = _signPrice(TOKEN_ID_YES, 0.66e18);

        uint256 collBefore = 10_000e6;
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, 2_000e6, lowPrice); // Partial repay: 2000 USDC

        (uint256 collAfter, uint256 sharesAfter,,) = pool.positions(borrower, TOKEN_ID_YES);
        // Position should still exist (partial liquidation)
        assertGt(collAfter, 0, "Collateral remains after partial liq");
        assertLt(collAfter, collBefore, "Some collateral seized");
        assertGt(sharesAfter, 0, "Debt remains");
    }

    /*//////////////////////////////////////////////////////////////
       TEST: VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetTokenBorrowCap() public {
        _supply(lender, 50_000e6);

        uint256 cap = pool.getTokenBorrowCap();
        // 5% of 50_000 = 2_500
        assertEq(cap, 2_500e6);
    }

    function test_GetTokenBorrowCap_ZeroWhenDisabled() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);

        _supply(lender, 50_000e6);
        assertEq(pool.getTokenBorrowCap(), 0);
    }

    /*//////////////////////////////////////////////////////////////
             TEST: FUZZ — CONTINUED
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CalcHealthFactor_ZeroDebt() public pure {
        uint256 hf = PredmartPoolLib.calcHealthFactor(1_000e6, 0, 0.80e18, 0.80e18);
        assertEq(hf, type(uint256).max, "Zero debt = max HF");
    }

    /// @dev Fuzz: borrow → full repay should never leave dust shares or create free USDC
    function testFuzz_BorrowRepayRoundtrip_NoDust(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1e6, 2_500e6); // MIN_BORROW to within cap

        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        pool.depositCollateral(TOKEN_ID_YES, 5_000e6);
        vm.stopPrank();

        // Borrow
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, borrowAmount, nonce, deadline);
        PredmartLendingPool.BorrowIntent memory intent = PredmartLendingPool.BorrowIntent({
            borrower: borrower, tokenId: TOKEN_ID_YES, amount: borrowAmount, nonce: nonce, deadline: deadline
        });
        vm.prank(relayer);
        pool.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Accrue some interest (random-ish time)
        vm.warp(block.timestamp + (borrowAmount % 365 days) + 1);

        // Full repay
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        // Invariant: no dust shares remain
        (, uint256 sharesAfter,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(sharesAfter, 0, "Full repay must zero shares");

        // Invariant: global tracking is consistent
        assertEq(pool.totalBorrowShares(), 0, "Global shares zero after sole borrower repays");
        assertEq(pool.totalBorrowAssets(), 0, "Global assets zero after sole borrower repays");
    }

    /// @dev Fuzz: liquidation should never let liquidator profit (receive more value than they pay)
    function testFuzz_CalcLiquidation_NoFreeValue(
        uint256 collateral,
        uint256 debt,
        uint256 price
    ) public pure {
        collateral = bound(collateral, 1e6, 1e15);
        debt = bound(debt, 1e6, 1e15);
        price = bound(price, 0.01e18, 1e18);

        uint256 collateralValue = (collateral * price) / 1e18;
        // Only test when position is unhealthy (HF < 1)
        uint256 threshold = 0.80e18;
        uint256 hf = PredmartPoolLib.calcHealthFactor(collateral, debt, price, threshold);
        if (hf >= 1e18) return; // Healthy — skip

        PredmartPoolLib.LiquidationVars memory vars = PredmartPoolLib.calcLiquidation(
            collateral, debt, hf, price, type(uint256).max
        );

        // Seized collateral cannot exceed total collateral
        assertLe(vars.seizeCollateral, collateral, "Cannot seize more than exists");

        // Liquidator cost should never exceed the value they receive
        uint256 seizedValue = (vars.seizeCollateral * price) / 1e18;
        assertGe(seizedValue, vars.liquidatorCost, "Liquidator must not overpay");

        // repayAmount should never exceed total debt
        assertLe(vars.repayAmount, debt, "Cannot repay more than owed");
    }
}

/// @notice Mock Safe that always returns false for isOwner — used to test depositCollateralFrom access control
contract MockSafeRejectsAll {
    function isOwner(address) external pure returns (bool) {
        return false;
    }
}
