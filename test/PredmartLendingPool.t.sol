// contracts/test/PredmartLendingPool.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { PredmartLendingPool } from "../src/PredmartLendingPool.sol";
import { PredmartOracle } from "../src/PredmartOracle.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { MockCTF } from "./mocks/MockCTF.sol";

contract PredmartLendingPoolTest is Test {
    PredmartLendingPool public pool;
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

        // Seed accounts
        usdc.mint(lender, 100_000e6);
        usdc.mint(borrower, 10_000e6);
        usdc.mint(liquidator, 100_000e6);
        usdc.mint(relayer, 100_000e6); // Relayer needs USDC for liquidations
        ctf.mint(borrower, TOKEN_ID_YES, 10_000e6);
        ctf.mint(borrower, TOKEN_ID_NO, 5_000e6);

        // Relayer approves pool for liquidation payments
        vm.prank(relayer);
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
        assertEq(keccak256(bytes(pool.VERSION())), keccak256(bytes("0.8.0")));
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
        pool.setPoolCapBps(0); // Disable cap — this test is about liquidity limits, not cap
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

        (uint256 collateral,,) = pool.positions(borrower, TOKEN_ID_YES);
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

        (uint256 collateral,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6);
    }

    function test_WithdrawCollateral_RevertsIfUnhealthy() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Try to withdraw too much collateral via relay
        uint256 nonce = pool.borrowNonces(borrower);
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

        (uint256 collateral, uint256 borrowShares,) = pool.positions(borrower, TOKEN_ID_YES);
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
        pool.setPoolCapBps(0); // Disable cap — this test is about liquidity limits
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

        (,uint256 debt,) = pool.positions(borrower, TOKEN_ID_YES);
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

        (,uint256 borrowShares,) = pool.positions(borrower, TOKEN_ID_YES);
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
        pool.setPoolCapBps(0); // Disable cap — this test is about liquidation mechanics
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
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, TOKEN_ID_YES);
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
        pool.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

        (bool resolved, bool won) = pool.resolvedMarkets(TOKEN_ID_YES);
        assertTrue(resolved);
        assertTrue(won);

        // Close position — should accrue final interest at $1.00
        pool.closeResolvedPosition(borrower, TOKEN_ID_YES);

        // Position should still exist (borrower needs to repay)
        (uint256 collateral,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
    }

    function test_ResolveMarket_Lost() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 totalAssetsBefore = pool.totalAssets();

        // Resolve market — borrower's shares lost
        pool.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, false));
        pool.closeResolvedPosition(borrower, TOKEN_ID_YES);

        // Position should be deleted (bad debt written off)
        (uint256 collateral, uint256 debt,) = pool.positions(borrower, TOKEN_ID_YES);
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

        pool.resolveMarket(TOKEN_ID_YES, _signResolution(TOKEN_ID_YES, true));

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
        pool.setPoolCapBps(0); // Disable cap — this test is about interest rate model
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
        pool.transferAdmin(newAdmin);
        assertEq(pool.admin(), newAdmin);
    }

    function test_TransferAdmin_RevertsNonAdmin() public {
        vm.prank(lender);
        vm.expectRevert(PredmartLendingPool.NotAdmin.selector);
        pool.transferAdmin(lender);
    }

    function test_SetOracle() public {
        address newOracle = makeAddr("newOracle");
        vm.startPrank(admin);
        pool.proposeOracle(newOracle);
        pool.executeOracle();
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
        pool.setPaused(true);
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
        pool.setPaused(true);

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
        pool.setPaused(true);

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
        pool.setPoolCapBps(0); // Disable cap — this test is about pause behavior
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        vm.prank(admin);
        pool.setPaused(true);

        // Liquidation still works (via relayer)
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));

        (uint256 collateral,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0);
    }

    function test_Unpause() public {
        vm.prank(admin);
        pool.setPaused(true);

        vm.prank(admin);
        pool.setPaused(false);
        assertFalse(pool.paused());

        // Borrow works again
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        (, uint256 borrowShares,) = pool.positions(borrower, TOKEN_ID_YES);
        assertGt(borrowShares, 0);
    }

    function test_SetAnchors() public {
        uint256[7] memory prices = [uint256(0), 0.15e18, 0.30e18, 0.50e18, 0.70e18, 0.85e18, 1.00e18];
        uint256[7] memory ltvs = [uint256(0.01e18), 0.05e18, 0.25e18, 0.40e18, 0.55e18, 0.65e18, 0.70e18];

        vm.startPrank(admin);
        pool.proposeAnchors(prices, ltvs);
        pool.executeAnchors();
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
        (uint256 collYes, uint256 sharesYes,) = pool.positions(borrower, TOKEN_ID_YES);
        (uint256 collNo, uint256 sharesNo,) = pool.positions(borrower, TOKEN_ID_NO);
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
        pool.setPoolCapBps(0); // Disable cap — this test is about position isolation
        _supply(lender, 50_000e6);

        // Two positions for the same borrower
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);
        _depositAndBorrow(borrower, TOKEN_ID_NO, 5_000e6, 2_000e6, 0.80e18);

        // YES price drops — position becomes unhealthy
        // NO price stays high — position is fine
        vm.prank(relayer);
        pool.liquidate(borrower, TOKEN_ID_YES, type(uint256).max, _signPrice(TOKEN_ID_YES, 0.50e18));

        // YES position liquidated
        (uint256 collYes,,) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collYes, 0);

        // NO position untouched
        (uint256 collNo, uint256 sharesNo,) = pool.positions(borrower, TOKEN_ID_NO);
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
        assertEq(pool.getTokenBorrowCap(), 0);
    }

    function test_BorrowCap_ScalesWithDeposits() public {
        _supply(lender, 50_000e6);
        // 5% of 50,000 = 2,500
        assertEq(pool.getTokenBorrowCap(), 2_500e6);
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
        pool.setPoolCapBps(1000); // 10%
        assertEq(pool.poolCapBps(), 1000);

        _supply(lender, 50_000e6);
        assertEq(pool.getTokenBorrowCap(), 5_000e6); // 10% of 50K
    }

    function test_BorrowCap_DisabledWhenZero() public {
        vm.prank(admin);
        pool.setPoolCapBps(0);

        _supply(lender, 50_000e6);
        assertEq(pool.getTokenBorrowCap(), 0);

        // Should still be able to borrow (cap disabled)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);
        assertEq(pool.totalBorrowedPerToken(TOKEN_ID_YES), 2_700e6);
    }

    // ─── Real-time view accrual ───

    function test_ViewFunctions_IncludePendingInterest() public {
        vm.prank(admin);
        pool.setPoolCapBps(0); // Disable cap — this test is about view function accrual
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
}
