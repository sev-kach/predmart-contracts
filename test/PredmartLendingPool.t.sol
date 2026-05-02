// contracts/test/PredmartLendingPool.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, Vm} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {PredmartLendingPool} from "../src/PredmartLendingPool.sol";
import {PredmartPoolExtension} from "../src/PredmartPoolExtension.sol";
import {PredmartBorrowExtension} from "../src/PredmartBorrowExtension.sol";
import {PredmartOracle} from "../src/PredmartOracle.sol";
import {PredmartPoolLib} from "../src/PredmartPoolLib.sol";
import {
    NotAdmin,
    InvalidAddress,
    NoPosition,
    TimelockNotReady,
    NoPendingChange,
    NotRelayer,
    NotLiquidator,
    TokenFrozen,
    CollateralDeposited,
    BadDebtAbsorbed
} from "../src/PredmartTypes.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockCTF} from "./mocks/MockCTF.sol";

contract PredmartLendingPoolTest is Test {
    PredmartLendingPool public pool;
    PredmartPoolExtension public poolAdmin; // Same address as pool, cast for admin function calls via fallback
    PredmartBorrowExtension public poolBorrow; // Same address as pool, cast for borrow/withdraw/leverage entries
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
    bytes32 public constant BORROW_INTENT_TYPEHASH =
        keccak256(
            "BorrowIntent(address borrower,address recipient,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant WITHDRAW_INTENT_TYPEHASH =
        keccak256(
            "WithdrawIntent(address borrower,address to,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant LEVERAGE_AUTH_TYPEHASH =
        keccak256(
            "LeverageAuth(address borrower,address allowedFrom,address recipient,uint256 tokenId,uint256 maxBorrow,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant CLOSE_AUTH_TYPEHASH =
        keccak256(
            "CloseAuth(address borrower,address allowedTo,uint256 tokenId,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant DEPOSIT_COLLATERAL_FROM_TYPEHASH =
        keccak256(
            "DepositCollateralFromAuth(address from,address creditTo,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)"
        );

    // CollateralDeposited event imported from PredmartTypes (used by vm.expectEmit)

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
        bytes memory initData = abi.encodeWithSelector(
            PredmartLendingPool.initialize.selector,
            admin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // Upgrade to v0.2.0
        PredmartLendingPool implV2 = new PredmartLendingPool();
        bytes memory initV2Data = abi.encodeWithSelector(
            PredmartLendingPool.initializeV2.selector,
            oracleAddress,
            address(usdc),
            address(ctf)
        );
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(
            address(implV2),
            initV2Data
        );

        // Initialize v0.6.0 — per-token borrow cap
        PredmartLendingPool(address(proxy)).initializeV3();

        // Upgrade to v0.8.0 — EIP-712 + relayer
        PredmartLendingPool implV4 = new PredmartLendingPool();
        vm.prank(admin);
        PredmartLendingPool(address(proxy)).upgradeToAndCall(
            address(implV4),
            abi.encodeWithSelector(
                PredmartLendingPool.initializeV4.selector,
                relayer
            )
        );

        pool = PredmartLendingPool(address(proxy));
        poolAdmin = PredmartPoolExtension(address(proxy));
        poolBorrow = PredmartBorrowExtension(address(proxy));

        // Deploy and set extension contract for admin functions
        PredmartPoolExtension ext = new PredmartPoolExtension();
        vm.prank(admin);
        pool.setExtension(address(ext));

        // V2 settleClose hits the canonical pUSD contract (0xC011a7...). In tests we
        // etch a MockUSDC there so settleClose can move pUSD without a fork.
        MockUSDC pusdImpl = new MockUSDC();
        vm.etch(address(0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB), address(pusdImpl).code);

        // Deploy BorrowExtension and route its selectors via the extension mapping.
        // Selector routing via initializeV19 runs only on real Safe-driven upgrades —
        // for tests, setExtensionSelectors is the bootstrap equivalent (no-timelock path).
        PredmartBorrowExtension borrowExt = new PredmartBorrowExtension();
        bytes4[] memory borrowSelectors = new bytes4[](5);
        borrowSelectors[0] = PredmartBorrowExtension.borrowViaRelay.selector;
        borrowSelectors[1] = PredmartBorrowExtension.leverageDeposit.selector;
        borrowSelectors[2] = PredmartBorrowExtension.depositCollateralFrom.selector;
        borrowSelectors[3] = PredmartBorrowExtension.withdrawViaRelay.selector;
        borrowSelectors[4] = PredmartBorrowExtension.pullUsdcForLeverage.selector;
        vm.prank(admin);
        pool.setExtensionSelectors(borrowSelectors, address(borrowExt));

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

        // Relayer approves pool
        vm.prank(relayer);
        usdc.approve(address(pool), type(uint256).max);

        // Relayer also funds + approves pUSD (V2 settleClose pulls pUSD for the surplus leg)
        MockUSDC pusdAt = MockUSDC(0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB);
        pusdAt.mint(relayer, 1_000_000e6);
        vm.prank(relayer);
        pusdAt.approve(address(pool), type(uint256).max);

        // Set liquidator wallet
        vm.prank(admin);
        poolAdmin.setLiquidator(liquidator);

        // Safe approves pool for deleverage repayments (USDC pull)
        vm.prank(safe);
        usdc.approve(address(pool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute EIP-712 domain separator for the pool
    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
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
        return _signBorrowIntentWithRecipient(
            signerKey, borrowerAddr, borrowerAddr, tokenId, amount, nonce, deadline
        );
    }

    function _signBorrowIntentWithRecipient(
        uint256 signerKey,
        address borrowerAddr,
        address recipient,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                BORROW_INTENT_TYPEHASH,
                borrowerAddr,
                recipient,
                tokenId,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
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
            abi.encode(
                WITHDRAW_INTENT_TYPEHASH,
                borrowerAddr,
                to,
                tokenId,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a LeverageAuth using EIP-712 (defaults recipient to borrower)
    function _signLeverageAuth(
        uint256 signerKey,
        address borrowerAddr,
        address allowedFrom,
        uint256 tokenId,
        uint256 maxBorrow,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signLeverageAuthWithRecipient(
            signerKey, borrowerAddr, allowedFrom, borrowerAddr, tokenId, maxBorrow, nonce, deadline
        );
    }

    function _signLeverageAuthWithRecipient(
        uint256 signerKey,
        address borrowerAddr,
        address allowedFrom,
        address recipient,
        uint256 tokenId,
        uint256 maxBorrow,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                LEVERAGE_AUTH_TYPEHASH,
                borrowerAddr,
                allowedFrom,
                recipient,
                tokenId,
                maxBorrow,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign a CloseAuth using EIP-712
    function _signCloseAuth(
        uint256 signerKey,
        address borrowerAddr,
        address allowedTo,
        uint256 tokenId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                CLOSE_AUTH_TYPEHASH,
                borrowerAddr,
                allowedTo,
                tokenId,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Helper: build LeverageDepositData struct (keeps test calls concise)
    function _ldd(
        address from,
        address borrowTo,
        uint256 depositAmount,
        uint256 borrowAmount
    ) internal pure returns (PredmartBorrowExtension.LeverageDepositData memory) {
        return
            PredmartBorrowExtension.LeverageDepositData({
                from: from,
                borrowTo: borrowTo,
                depositAmount: depositAmount,
                borrowAmount: borrowAmount
            });
    }

    /// @dev Sign a DepositCollateralFromAuth using EIP-712
    function _signDepositCollateralFromAuth(
        uint256 signerKey,
        address from,
        address creditTo,
        uint256 tokenId,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_COLLATERAL_FROM_TYPEHASH,
                from,
                creditTo,
                tokenId,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Create a signed PriceData struct
    function _signPrice(
        uint256 tokenId,
        uint256 price
    ) internal view returns (PredmartOracle.PriceData memory) {
        return _signPriceAt(tokenId, price, block.timestamp);
    }

    function _signPriceAt(
        uint256 tokenId,
        uint256 price,
        uint256 timestamp
    ) internal view returns (PredmartOracle.PriceData memory) {
        uint256 maxBorrow = type(uint256).max; // No depth cap in tests
        bytes32 hash = keccak256(
            abi.encodePacked(
                block.chainid,
                address(pool),
                tokenId,
                price,
                timestamp,
                maxBorrow
            )
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        return
            PredmartOracle.PriceData({
                tokenId: tokenId,
                price: price,
                timestamp: timestamp,
                maxBorrow: maxBorrow,
                signature: signature
            });
    }

    function _signResolution(
        uint256 tokenId,
        bool won
    ) internal view returns (PredmartOracle.ResolutionData memory) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                "RESOLVE",
                block.chainid,
                address(pool),
                tokenId,
                won,
                block.timestamp
            )
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePrivateKey, ethHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        return
            PredmartOracle.ResolutionData({
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
        poolAdmin.depositCollateral(
            _borrower,
            tokenId,
            collateralAmount,
            _signPrice(tokenId, price)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(_borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: _borrower,
                recipient: _borrower,
                tokenId: tokenId,
                amount: borrowAmount,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            _borrower,
            tokenId,
            borrowAmount,
            nonce,
            deadline
        );

        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(tokenId, price));
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
        assertEq(
            keccak256(bytes(pool.name())),
            keccak256(bytes("Predmart USDC"))
        );
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
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
        assertEq(ctf.balanceOf(address(pool), TOKEN_ID_YES), 5_000e6);
    }

    function test_WithdrawCollateral_NoDebt() public {
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Withdraw via relay (no debt, so price verification is skipped)
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 2_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline
        );

        // Dummy price data (won't be verified since no debt)
        PredmartOracle.PriceData memory dummyPrice = _signPrice(
            TOKEN_ID_YES,
            0.80e18
        );

        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, dummyPrice);

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6);
    }

    function test_WithdrawCollateral_RevertsIfUnhealthy() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Try to withdraw too much collateral via relay
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 4_500e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            4_500e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.ExceedsLTV.selector);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /*//////////////////////////////////////////////////////////////
                        TEST: BORROW/REPAY
    //////////////////////////////////////////////////////////////*/

    function test_Borrow() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        (uint256 collateral, uint256 borrowShares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 5_000e6);
        assertGt(borrowShares, 0);
        assertEq(pool.totalBorrowAssets(), 2_000e6);
        assertEq(usdc.balanceOf(borrower), 12_000e6); // 10_000 initial + 2_000 borrowed
    }

    function test_Borrow_RevertsExceedsLTV() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // At $0.80 price, LTV is 70%. Max borrow = 5000 * 0.80 * 0.70 = 2800
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 3_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            3_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.ExceedsLTV.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Borrow_RevertsInsufficientLiquidity() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about liquidity limits
        _supply(lender, 1_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            10_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 2_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InsufficientLiquidity.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Repay_Full() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        poolAdmin.repay(borrower, TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        (, uint256 debt, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(debt, 0);
        assertEq(pool.totalBorrowAssets(), 0);
    }

    function test_Repay_Partial() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        poolAdmin.repay(borrower, TOKEN_ID_YES, 500e6);
        vm.stopPrank();

        (, uint256 borrowShares, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
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
        poolAdmin.accrueInterest();

        // Debt should be significantly more than 2000 after 1 year of interest
        // Base rate ~5% + utilization-driven rate, times rate multiplier of 1.25x at $0.80
        assertGt(
            pool.totalBorrowAssets(),
            2_000e6,
            "totalBorrowed should include interest"
        );
        assertGt(pool.totalReserves(), 0, "Reserves should have accumulated");
    }

    function test_InterestIncreasesTotalAssets() public {
        _supply(lender, 50_000e6);
        uint256 totalAssetsBefore = pool.totalAssets();

        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Trigger accrual
        poolAdmin.accrueInterest();

        uint256 totalAssetsAfter = pool.totalAssets();
        assertGt(
            totalAssetsAfter,
            totalAssetsBefore,
            "totalAssets should grow from interest"
        );
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
        PredmartOracle.PriceData memory lowPrice = _signPrice(
            TOKEN_ID_YES,
            0.50e18
        );

        // Liquidator calls liquidate
        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, lowPrice);

        // Position should be deleted
        (uint256 collateral, uint256 debt, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 0);
        assertEq(debt, 0);

        // Liquidator received the shares (collateral goes to msg.sender)
        assertEq(ctf.balanceOf(liquidator, TOKEN_ID_YES), 5_000e6);

        // Pool totalBorrowed should decrease
        assertEq(pool.totalBorrowAssets(), 0);
    }

    function test_Liquidation_RevertsIfHealthy() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Price stays at $0.80 — position is healthy
        vm.expectRevert(PredmartPoolExtension.PositionHealthy.selector);
        vm.prank(liquidator);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_Liquidate_RevertsNotLiquidator() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Non-liquidator (relayer) tries to liquidate — reverts
        vm.expectRevert(NotLiquidator.selector);
        vm.prank(relayer);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.50e18)
        );
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: MARKET RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_ResolveMarket_Won() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Resolve market — borrower's shares won
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );

        (bool resolved, bool won) = pool.resolvedMarkets(TOKEN_ID_YES);
        assertTrue(resolved);
        assertTrue(won);

        // closeLostPosition should revert on won markets — must use redemption flow
        vm.expectRevert(PredmartPoolExtension.UseRedemptionFlow.selector);
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);

        // Position should still exist (must go through redeemWonCollateral + settleRedemption)
        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 5_000e6);
    }

    function test_ResolveMarket_Lost() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 totalAssetsBefore = pool.totalAssets();

        // Resolve market — borrower's shares lost
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, false)
        );
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);

        // Position should be deleted (bad debt written off)
        (uint256 collateral, uint256 debt, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
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

        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );

        vm.startPrank(borrower);
        vm.expectRevert(PredmartBorrowExtension.MarketResolved.selector);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
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
        // No borrows — should return base rate (10%)
        assertEq(pool.getBorrowRate(), 0.10e18);
    }

    function test_BorrowRate_AtKink() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0); // Disable cap — this test is about interest rate model
        _supply(lender, 10_000e6);
        // Borrow within LTV: 5000 collateral at $1.00, LTV=75%, max=3750. Borrow 3500.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 3_500e6, 1e18);
        // Utilization = 3500 / 10000 = 35%
        uint256 rate = pool.getBorrowRate();
        assertGt(
            rate,
            0.05e18,
            "Rate should be above base at non-zero utilization"
        );
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
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Create price data with old timestamp (61 seconds ago, exceeds MAX_RELAY_PRICE_AGE of 60 seconds)
        PredmartOracle.PriceData memory stalePrice = _signPriceAt(
            TOKEN_ID_YES,
            0.80e18,
            block.timestamp - 61 seconds
        );

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.PriceTooOld.selector);
        poolBorrow.borrowViaRelay(intent, sig, stalePrice);
    }

    function test_Oracle_RejectsWrongSigner() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Sign with wrong key
        uint256 wrongKey = 0xBAD;
        uint256 maxBorrow = type(uint256).max;
        bytes32 hash = keccak256(
            abi.encodePacked(
                block.chainid,
                address(pool),
                TOKEN_ID_YES,
                uint256(0.80e18),
                block.timestamp,
                maxBorrow
            )
        );
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
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.InvalidOracleSignature.selector);
        poolBorrow.borrowViaRelay(intent, sig, badPrice);
    }

    function test_Oracle_RejectsPriceAboveDollar() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartOracle.PriceTooHigh.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 1.5e18));
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

    /// @dev   L-02: instant-transfer branch (timelockDelay=0) must emit AdminTransferred
    ///      so off-chain observers can track the change.
    function test_TransferAdmin_L02_EmitsEventInInstantBranch() public {
        // timelockDelay is 0 in fresh test setup — this hits the instant path
        address newAdmin = makeAddr("newAdmin");

        vm.expectEmit(true, true, false, false);
        emit PredmartPoolExtension.AdminTransferred(admin, newAdmin);

        vm.prank(admin);
        poolAdmin.transferAdmin(newAdmin);

        assertEq(pool.admin(), newAdmin, "Admin changed");
    }

    function test_TransferAdmin_RevertsNonAdmin() public {
        vm.prank(lender);
        vm.expectRevert(NotAdmin.selector);
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
        poolAdmin.accrueInterest();

        uint256 reserves = pool.totalReserves();
        assertGt(reserves, 0, "Should have reserves");

        uint256 adminBalanceBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        poolAdmin.withdrawReserves(reserves);

        assertEq(usdc.balanceOf(admin), adminBalanceBefore + reserves);
        assertEq(pool.totalReserves(), 0);
    }

    function test_Pause_BlocksBorrow() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Admin pauses
        vm.prank(admin);
        poolAdmin.setPaused(true);
        assertTrue(pool.paused());

        // Borrow via relay should revert
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartLendingPool.ProtocolPaused.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Pause_BlocksDepositCollateral() public {
        vm.prank(admin);
        poolAdmin.setPaused(true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        vm.expectRevert(PredmartLendingPool.ProtocolPaused.selector);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
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
        poolAdmin.repay(borrower, TOKEN_ID_YES, 500e6);
        vm.stopPrank();

        assertEq(pool.totalBorrowAssets(), 1_500e6);

        // Lender withdraw still works
        uint256 redeemable = pool.maxRedeem(lender);
        assertGt(redeemable, 0);
    }

    function test_Pause_AllowsLiquidation() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_700e6, 0.80e18);

        // Set liquidator and pause
        vm.prank(admin);
        poolAdmin.setLiquidator(liquidator);
        vm.prank(admin);
        poolAdmin.setPaused(true);

        // v2: liquidation works during pause (lender protection takes priority)
        vm.prank(liquidator);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.50e18)
        );

        (uint256 col, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(col, 0, "Position liquidated even while paused");
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

        (, uint256 borrowShares, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertGt(borrowShares, 0);
    }

    function test_SetAnchors() public {
        uint256[7] memory prices = [
            uint256(0),
            0.15e18,
            0.30e18,
            0.50e18,
            0.70e18,
            0.85e18,
            1.00e18
        ];
        uint256[7] memory ltvs = [
            uint256(0.01e18),
            0.05e18,
            0.25e18,
            0.40e18,
            0.55e18,
            0.65e18,
            0.70e18
        ];

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
        (uint256 collYes, uint256 sharesYes, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        (uint256 collNo, uint256 sharesNo, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_NO
        );
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
        vm.prank(liquidator);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.50e18)
        );

        // YES position liquidated
        (uint256 collYes, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collYes, 0);

        // NO position untouched
        (uint256 collNo, uint256 sharesNo, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_NO
        );
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
        poolAdmin.accrueInterest();

        uint256 valueAfterPerShare = pool.convertToAssets(1e12);
        assertGt(
            valueAfterPerShare,
            valueBeforePerShare,
            "pUSDC should be worth more after interest accrues"
        );

        // Lender shares unchanged
        assertEq(pool.balanceOf(lender), sharesBefore);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: PER-TOKEN BORROW CAP
    //////////////////////////////////////////////////////////////*/

    function test_BorrowCap_InitializedTo5Percent() public view {
        assertEq(pool.poolCapBps(), 500);
        // Pool has 0 deposits, so cap is 0
        assertEq((pool.totalAssets() * pool.poolCapBps()) / 10000, 0);
    }

    function test_BorrowCap_ScalesWithDeposits() public {
        _supply(lender, 50_000e6);
        // 5% of 50,000 = 2,500
        assertEq((pool.totalAssets() * pool.poolCapBps()) / 10000, 2_500e6);
    }

    function test_BorrowCap_BlocksExcessiveBorrow() public {
        _supply(lender, 50_000e6);
        // Cap = 2,500 USDC per token. Try to borrow 2,600 at price $0.80 with 5000 collateral.
        // LTV at 0.80 = 70%, maxBorrow = 5000 * 0.80 * 0.70 = 2,800 — within LTV but exceeds cap.
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 2_600e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            2_600e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.ExceedsTokenCap.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
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
        poolAdmin.repay(borrower, TOKEN_ID_YES, 1_000e6);
        vm.stopPrank();

        // Should have decreased by the repay amount
        assertApproxEqAbs(
            pool.totalBorrowedPerToken(TOKEN_ID_YES),
            1_000e6,
            100
        );
    }

    function test_BorrowCap_DecreasesOnLiquidation() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        uint256 trackedBefore = pool.totalBorrowedPerToken(TOKEN_ID_YES);
        assertEq(trackedBefore, 2_000e6);

        // Price drops → liquidate (via relayer)
        vm.prank(liquidator);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.50e18)
        );

        // Tracked amount should decrease
        assertLt(pool.totalBorrowedPerToken(TOKEN_ID_YES), trackedBefore);
    }

    function test_BorrowCap_AdminCanUpdate() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(1000); // 10%
        assertEq(pool.poolCapBps(), 1000);

        _supply(lender, 50_000e6);
        assertEq((pool.totalAssets() * pool.poolCapBps()) / 10000, 5_000e6); // 10% of 50K
    }

    function test_BorrowCap_DisabledWhenZero() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);

        _supply(lender, 50_000e6);
        assertEq((pool.totalAssets() * pool.poolCapBps()) / 10000, 0);

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
        assertGt(
            debtAfter,
            debtAtBorrow,
            "Debt should grow with pending interest"
        );
        // totalAssets should have grown (lenders earn yield)
        assertGt(
            totalAssetsAfter,
            totalAssetsAtBorrow,
            "totalAssets should include pending interest"
        );

        // Health factor should be lower (debt grew, collateral unchanged)
        uint256 hfAtBorrow = pool.getHealthFactor(
            borrower,
            TOKEN_ID_YES,
            0.80e18
        );
        assertLt(
            hfAtBorrow,
            type(uint256).max,
            "HF should be finite with debt"
        );

        // Verify accrueInterest() produces the same result (consistency check)
        poolAdmin.accrueInterest();
        uint256 debtAfterAccrual = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsAfterAccrual = pool.totalAssets();
        assertEq(
            debtAfter,
            debtAfterAccrual,
            "View debt should match post-accrual debt"
        );
        assertEq(
            totalAssetsAfter,
            totalAssetsAfterAccrual,
            "View totalAssets should match post-accrual"
        );
    }

    /*//////////////////////////////////////////////////////////////
                   TEST: RELAY INTENT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_BorrowViaRelay_RevertsNotRelayer() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        // Non-relayer tries to call borrowViaRelay
        vm.prank(liquidator);
        vm.expectRevert(NotRelayer.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsExpiredIntent() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp - 1; // Already expired
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.IntentExpired.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsInvalidNonce() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 wrongNonce = 999; // Wrong nonce (should be 0)
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: wrongNonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            wrongNonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InvalidNonce.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_BorrowViaRelay_RevertsInvalidSignature() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        // Sign with wrong key (relayer's key instead of borrower's)
        bytes memory wrongSig = _signBorrowIntent(
            relayerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.borrowViaRelay(
            intent,
            wrongSig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_BorrowViaRelay_IncrementsNonce() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonceBefore = pool.borrowNonces(borrower);
        assertEq(nonceBefore, 0);

        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonceBefore,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonceBefore,
            deadline
        );

        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        uint256 nonceAfter = pool.borrowNonces(borrower);
        assertEq(nonceAfter, 1);
    }

    /*//////////////////////////////////////////////////////////////
              TEST: EXTENSION — TIMELOCKED ADMIN FLOWS
    //////////////////////////////////////////////////////////////*/

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
        vm.expectRevert(TimelockNotReady.selector);
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

        assertEq(
            pool.pendingAdmin(),
            address(0),
            "Pending cleared after cancel"
        );
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

        assertEq(
            pool.oracle(),
            oracleAddress,
            "Oracle unchanged before timelock"
        );

        // Revert before timelock
        vm.prank(admin);
        vm.expectRevert(TimelockNotReady.selector);
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

        uint256[7] memory prices = [
            uint256(0),
            0.15e18,
            0.30e18,
            0.50e18,
            0.70e18,
            0.85e18,
            1.00e18
        ];
        uint256[7] memory ltvs = [
            uint256(0.01e18),
            0.05e18,
            0.25e18,
            0.40e18,
            0.55e18,
            0.65e18,
            0.70e18
        ];

        vm.prank(admin);
        poolAdmin.proposeAnchors(prices, ltvs);

        // Not yet executable
        vm.prank(admin);
        vm.expectRevert(TimelockNotReady.selector);
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

        uint256[7] memory prices = [
            uint256(0),
            0.15e18,
            0.30e18,
            0.50e18,
            0.70e18,
            0.85e18,
            1.00e18
        ];
        uint256[7] memory ltvs = [
            uint256(0.01e18),
            0.05e18,
            0.25e18,
            0.40e18,
            0.55e18,
            0.65e18,
            0.70e18
        ];

        vm.prank(admin);
        poolAdmin.proposeAnchors(prices, ltvs);

        vm.prank(admin);
        poolAdmin.cancelPending(3); // kind=3 is anchors

        // Original anchors unchanged
        assertEq(pool.priceAnchors(1), 0.10e18);
    }

    function test_TimelockAnchors_RevertsInvalidAnchors() public {
        // LTV + LIQUIDATION_BUFFER > 1.0 should revert
        uint256[7] memory prices = [
            uint256(0),
            0.10e18,
            0.20e18,
            0.40e18,
            0.60e18,
            0.80e18,
            1.00e18
        ];
        uint256[7] memory badLtvs = [
            uint256(0.02e18),
            0.08e18,
            0.30e18,
            0.45e18,
            0.60e18,
            0.70e18,
            0.95e18
        ]; // 95% + 10% > 100%

        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.InvalidAnchors.selector);
        poolAdmin.proposeAnchors(prices, badLtvs);
    }

    function test_TimelockAnchors_RevertsNonMonotonicPrices() public {
        // Prices must be strictly increasing
        uint256[7] memory badPrices = [
            uint256(0),
            0.10e18,
            0.20e18,
            0.15e18,
            0.60e18,
            0.80e18,
            1.00e18
        ]; // 0.15 < 0.20
        uint256[7] memory ltvs = [
            uint256(0.02e18),
            0.08e18,
            0.30e18,
            0.45e18,
            0.60e18,
            0.70e18,
            0.75e18
        ];

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

    /// @dev   L-03: reject delays above MAX_TIMELOCK_DELAY (10 days).
    ///      Without this cap, a fat-finger value could permanently brick governance.
    function test_ActivateTimelock_L03_RevertsAboveMaximum() public {
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockExceedsMaximum.selector);
        poolAdmin.activateTimelock(11 days);
    }

    function test_ActivateTimelock_L03_AllowsExactlyMaximum() public {
        vm.prank(admin);
        poolAdmin.activateTimelock(10 days);
        assertEq(
            pool.timelockDelay(),
            10 days,
            "Exactly MAX_TIMELOCK_DELAY accepted"
        );
    }

    function test_ActivateTimelock_L03_RevertsHugeValue() public {
        vm.prank(admin);
        vm.expectRevert(PredmartPoolExtension.TimelockExceedsMaximum.selector);
        poolAdmin.activateTimelock(type(uint256).max);
    }

    function test_ExecuteAddress_RevertsNoPendingChange() public {
        _activateTimelock();

        // No pending oracle change — should revert
        vm.prank(admin);
        vm.expectRevert(NoPendingChange.selector);
        poolAdmin.executeAddress(0);

        // No pending relayer change
        vm.prank(admin);
        vm.expectRevert(NoPendingChange.selector);
        poolAdmin.executeAddress(1);
    }

    function test_ExecuteTransferAdmin_RevertsNoPendingChange() public {
        _activateTimelock();

        vm.prank(admin);
        vm.expectRevert(NoPendingChange.selector);
        poolAdmin.executeTransferAdmin();
    }

    function test_ProposeAddress_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(InvalidAddress.selector);
        poolAdmin.proposeAddress(0, address(0));
    }

    function test_TransferAdmin_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(InvalidAddress.selector);
        poolAdmin.transferAdmin(address(0));
    }

    /*//////////////////////////////////////////////////////////////
            TEST: L-01 — TIMELOCKED EXTENSION ROTATION
    //////////////////////////////////////////////////////////////*/

    function test_ProposeExtension_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(InvalidAddress.selector);
        pool.proposeExtension(address(0));
    }

    function test_ProposeExtension_RevertsNotAdmin() public {
        PredmartPoolExtension newExt = new PredmartPoolExtension();
        vm.prank(borrower);
        vm.expectRevert(NotAdmin.selector);
        pool.proposeExtension(address(newExt));
    }

    function test_ExecuteExtension_RevertsNoPendingChange() public {
        vm.prank(admin);
        vm.expectRevert(NoPendingChange.selector);
        pool.executeExtension();
    }

    function test_ExecuteExtension_RevertsTimelockNotReady() public {
        _activateTimelock();
        PredmartPoolExtension newExt = new PredmartPoolExtension();

        vm.prank(admin);
        pool.proposeExtension(address(newExt));

        // Try to execute before timelock elapses
        vm.prank(admin);
        vm.expectRevert(TimelockNotReady.selector);
        pool.executeExtension();
    }

    function test_ProposeExecuteExtension_HappyPath() public {
        _activateTimelock();
        PredmartPoolExtension newExt = new PredmartPoolExtension();
        address oldExt = pool.extension();

        vm.prank(admin);
        pool.proposeExtension(address(newExt));

        assertEq(pool.pendingExtension(), address(newExt), "Pending set");
        assertEq(
            pool.extension(),
            oldExt,
            "Current extension unchanged during propose"
        );

        // Wait out the timelock
        vm.warp(pool.pendingExtensionExecAfter());

        vm.prank(admin);
        pool.executeExtension();

        assertEq(pool.extension(), address(newExt), "Extension rotated");
        assertEq(pool.pendingExtension(), address(0), "Pending cleared");
        assertEq(pool.pendingExtensionExecAfter(), 0, "ExecAfter cleared");
    }

    function test_ProposeExtension_OverwriteReplacesPending() public {
        _activateTimelock();
        PredmartPoolExtension ext1 = new PredmartPoolExtension();
        PredmartPoolExtension ext2 = new PredmartPoolExtension();

        vm.prank(admin);
        pool.proposeExtension(address(ext1));
        assertEq(pool.pendingExtension(), address(ext1));

        vm.prank(admin);
        pool.proposeExtension(address(ext2));
        assertEq(
            pool.pendingExtension(),
            address(ext2),
            "Second proposal overwrites first"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: LEVERAGE STEP
    //////////////////////////////////////////////////////////////*/

    function test_LeverageStep_DepositAndBorrow() public {
        _supply(lender, 50_000e6);

        // Borrower deposits collateral first
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            3_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Relayer holds some CTF shares (simulating post-CLOB purchase)
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6;

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: maxBorrow,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            maxBorrow,
            nonce,
            deadline
        );

        // Relayer deposits 2000 shares (from relayer itself) + borrows 1000 USDC
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 2_000e6, 1_000e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        // Verify: borrower's position now has 5000 collateral (3000 initial + 2000 from leverage)
        (uint256 collateral, uint256 borrowShares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 5_000e6, "Collateral includes leveraged deposit");
        assertGt(borrowShares, 0, "Borrow shares created");
        assertEq(
            pool.leverageNonces(borrower),
            nonce + 1,
            "Nonce consumed on first borrow"
        );
    }

    function test_LeverageStep_DepositOnly() public {
        _supply(lender, 50_000e6);

        // Borrower deposits some initial collateral
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Relayer has shares
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6;

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: maxBorrow,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            maxBorrow,
            nonce,
            deadline
        );

        // Deposit only, no borrow — nonce should NOT be consumed
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 2_000e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 3_000e6, "Collateral increased");
        assertEq(
            pool.leverageNonces(borrower),
            nonce,
            "Nonce unchanged on deposit-only"
        );
    }

    function test_LeverageStep_MultipleStepsBudgetTracking() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        uint256 maxBorrow = 2_000e6; // Budget: max 2000 USDC total

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: maxBorrow,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            maxBorrow,
            nonce,
            deadline
        );

        // Step 1: borrow 800
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 800e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        // Step 2: borrow 800 more (total 1600 < 2000 budget)
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 800e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        // Step 3: try to borrow 500 more (total 2100 > 2000 budget)
        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.ExceedsBorrowBudget.selector);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 500e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        // Step 3 corrected: borrow exactly remaining 400
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 400e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        assertEq(
            pool.totalBorrowAssets(),
            2_000e6,
            "Total borrowed matches budget"
        );
    }

    function test_LeverageStep_RevertsNotRelayer() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(liquidator);
        vm.expectRevert(NotRelayer.selector);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 500e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_LeverageStep_RevertsExpired() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp - 1; // Already expired
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.IntentExpired.selector);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 0, 500e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_LeverageStep_RevertsInvalidFrom() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe, // Only safe or relayer allowed
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        address attacker = makeAddr("attacker");
        vm.prank(relayer);
        vm.expectRevert(InvalidAddress.selector);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(attacker, relayer, 500e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_LeverageStep_RevertsInvalidSignature() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        // Sign with wrong key
        bytes memory wrongSig = _signLeverageAuth(
            relayerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.leverageDeposit(
            auth,
            wrongSig,
            "",
            _ldd(relayer, relayer, 0, 500e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /*//////////////////////////////////////////////////////////////
        TEST: LEVERAGE DEPOSIT (  H-03 — allowedFrom consent)
    //////////////////////////////////////////////////////////////*/

    /// @dev H-03 attack: attacker signs LeverageAuth with allowedFrom=VICTIM_SAFE. Victim has
    ///      granted setApprovalForAll on CTF to the pool. Without fromSignature, contract must reject.
    function test_LeverageDeposit_H03_AttackBlocked_MissingFromSignature()
        public
    {
        _supply(lender, 50_000e6);

        // Victim has granted CTF approval (standard for any user who ever deposited collateral)
        uint256 victimKey = 0xDEAD;
        address victim = vm.addr(victimKey);
        ctf.mint(victim, TOKEN_ID_YES, 5_000e6);
        vm.prank(victim);
        ctf.setApprovalForAll(address(pool), true);

        // Attacker signs auth with victim as allowedFrom
        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower, // attacker
                allowedFrom: victim, // attacker-controlled: points to victim
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 0,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory authSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            victim,
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.leverageDeposit(
            auth,
            authSig,
            "",
            /* no fromSig */ _ldd(victim, relayer, 2_000e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /// @dev Legitimate flow: allowedFrom (separate wallet) signs the same authHash.
    function test_LeverageDeposit_LegitimateFlow_AllowedFromSigns() public {
        _supply(lender, 50_000e6);

        uint256 safeOwnerKey = 0x5AFE;
        address safeOwner = vm.addr(safeOwnerKey);
        ctf.mint(safeOwner, TOKEN_ID_YES, 5_000e6);
        vm.prank(safeOwner);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safeOwner,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 0,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory authSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safeOwner,
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );
        bytes memory fromSig = _signLeverageAuth(
            safeOwnerKey,
            borrower,
            safeOwner,
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );

        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            authSig,
            fromSig,
            _ldd(safeOwner, relayer, 2_000e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 2_000e6, "Shares credited to borrower's position");
        assertEq(
            ctf.balanceOf(safeOwner, TOKEN_ID_YES),
            3_000e6,
            "Shares pulled from safeOwner"
        );
    }

    /// @dev Existing relayer-deposit flow still works: from=relayer, no fromSig needed.
    ///      (This is the primary path after a CLOB buy — shares sit in relayer before deposit.)
    function test_LeverageDeposit_FromRelayer_NoFromSigNeeded() public {
        _supply(lender, 50_000e6);

        ctf.mint(relayer, TOKEN_ID_YES, 5_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe, // different from borrower, unused
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 0,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory authSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );

        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            authSig,
            "",
            _ldd(relayer, relayer, 2_000e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 2_000e6, "Shares credited to borrower's position");
    }

    /// @dev depositAmount=0 (borrow-only or settle-advance) does not require fromSignature.
    function test_LeverageDeposit_DepositAmountZero_NoFromSigNeeded() public {
        _supply(lender, 50_000e6);

        // Pre-deposit some collateral directly so a borrow against it is possible
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            3_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe, // not borrower, but unused (depositAmount=0)
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory authSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        // from = relayer, depositAmount = 0 — pure borrow, no fromSig required
        poolBorrow.leverageDeposit(
            auth,
            authSig,
            "",
            _ldd(relayer, relayer, 0, 500e6),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        assertEq(
            pool.leverageNonces(borrower),
            nonce + 1,
            "Nonce consumed on first borrow"
        );
    }

    /*//////////////////////////////////////////////////////////////
       TEST: EIP-1271 EDGE CASES (H-01 / H-02 / H-03 signature paths)
    //////////////////////////////////////////////////////////////*/

    /// @dev Gnosis Safe-style contract validates owner's signature via EIP-1271 → deposit succeeds.
    function test_DepositCollateralFrom_EIP1271_ValidSafeSignature() public {
        uint256 ownerKey = 0x5A5E_0;
        address ownerAddr = vm.addr(ownerKey);
        MockSafe1271 safe1271 = new MockSafe1271(ownerAddr);

        ctf.mint(address(safe1271), TOKEN_ID_YES, 5_000e6);
        vm.prank(address(safe1271));
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(address(safe1271));
        uint256 deadline = block.timestamp + 300;
        // Owner signs on behalf of the Safe — Safe's isValidSignature validates via ECDSA recovery
        bytes memory sig = _signDepositCollateralFromAuth(
            ownerKey,
            address(safe1271),
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        poolBorrow.depositCollateralFrom(
            address(safe1271),
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 1_000e6, "Shares credited to borrower's position");
    }

    /// @dev Contract returns a non-magic value → SignatureChecker rejects → reverts with InvalidIntentSignature.
    function test_DepositCollateralFrom_EIP1271_WrongMagicValue_Reverts()
        public
    {
        MockSafe1271WrongMagic badSafe = new MockSafe1271WrongMagic();
        ctf.mint(address(badSafe), TOKEN_ID_YES, 5_000e6);
        vm.prank(address(badSafe));
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(address(badSafe));
        uint256 deadline = block.timestamp + 300;
        // Any signature bytes — the mock will return wrong magic regardless
        bytes memory sig = hex"deadbeef";

        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.depositCollateralFrom(
            address(badSafe),
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /// @dev Contract whose isValidSignature reverts — SignatureChecker must handle gracefully
    ///      and the overall tx must revert with InvalidIntentSignature (not bubble up the inner revert).
    function test_DepositCollateralFrom_EIP1271_Reverts_HandledGracefully()
        public
    {
        MockSafe1271Reverts revertingSafe = new MockSafe1271Reverts();
        ctf.mint(address(revertingSafe), TOKEN_ID_YES, 5_000e6);
        vm.prank(address(revertingSafe));
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(
            address(revertingSafe)
        );
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = hex"deadbeef";

        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.depositCollateralFrom(
            address(revertingSafe),
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /// @dev H-03: Same spoofing attempt for leverageDeposit. Safe rejects attacker's own signature.
    function test_LeverageDeposit_EIP1271_AttackerCannotSpoofSafe() public {
        _supply(lender, 50_000e6);

        uint256 ownerKey = 0x5A5E_2;
        address ownerAddr = vm.addr(ownerKey);
        MockSafe1271 victimSafe = new MockSafe1271(ownerAddr);
        ctf.mint(address(victimSafe), TOKEN_ID_YES, 5_000e6);
        vm.prank(address(victimSafe));
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: address(victimSafe),
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 0,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory authSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            address(victimSafe),
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );
        bytes memory forgedFromSig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            address(victimSafe),
            TOKEN_ID_YES,
            0,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.leverageDeposit(
            auth,
            authSig,
            forgedFromSig,
            _ldd(address(victimSafe), relayer, 2_000e6, 0),
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /*//////////////////////////////////////////////////////////////
              TEST: EDGE CASES — BORROW BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_Borrow_RevertsBorrowTooSmall() public {
        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Try to borrow $0.50 — below MIN_BORROW ($1)
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 0.5e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            0.5e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.BorrowTooSmall.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_Borrow_ExactlyMinBorrow() public {
        _supply(lender, 50_000e6);

        // Borrow exactly $1 (MIN_BORROW = 1e6)
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 1e6, 0.80e18);

        (, uint256 borrowShares, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
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
        poolAdmin.repay(borrower, TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        (, uint256 borrowShares, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
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
        vm.expectRevert(TokenFrozen.selector);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();
    }

    function test_FrozenToken_BlocksBorrow() public {
        _supply(lender, 50_000e6);

        // Deposit before freeze
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Freeze the token
        vm.prank(admin);
        poolAdmin.setTokenFrozen(TOKEN_ID_YES, true);

        // Try to borrow — should revert
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: 1_000e6,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.prank(relayer);
        vm.expectRevert(TokenFrozen.selector);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
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
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
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
        poolAdmin.accrueInterest();

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        // Price crashes to $0.10 — collateral value = 5000 * 0.10 = $500
        // Debt >> $500 → underwater
        PredmartOracle.PriceData memory crashPrice = _signPrice(
            TOKEN_ID_YES,
            0.10e18
        );

        uint256 totalAssetsBefore = pool.totalAssets();

        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, crashPrice);

        // Position fully deleted
        (uint256 collateral, uint256 shares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // v2: totalAssets stable after liquidate() — debt moved to totalPendingLiquidations
        // Bad debt only realized on settleLiquidation with insufficient proceeds
        uint256 totalAssetsAfterLiq = pool.totalAssets();

        // Settle with 0 proceeds (shares worthless) → bad debt
        vm.prank(liquidator);
        poolAdmin.settleLiquidation(borrower, TOKEN_ID_YES, 0);

        assertLt(
            pool.totalAssets(),
            totalAssetsAfterLiq,
            "Bad debt socialized to lenders after settlement"
        );
    }

    /*//////////////////////////////////////////////////////////////
       TEST: CLOSE RESOLVED POSITION — WON MARKET (no-op behavior)
    //////////////////////////////////////////////////////////////*/

    function test_CloseResolvedPosition_WonMarket_Reverts() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        // Resolve as won
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );

        // closeLostPosition reverts on won markets — must use redemption flow
        vm.expectRevert(PredmartPoolExtension.UseRedemptionFlow.selector);
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);

        // Position untouched
        (uint256 collateral, uint256 borrowSharesAfter, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 5_000e6, "Collateral preserved");
        assertGt(borrowSharesAfter, 0, "Debt preserved");
    }

    function test_CloseResolvedPosition_LostMarket_DeletesPosition() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, false)
        );
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);

        (uint256 collateral, uint256 shares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 0, "Position deleted on lost market");
        assertEq(shares, 0);
    }

    function test_CloseResolvedPosition_RevertsNotResolved() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        vm.expectRevert(PredmartPoolExtension.MarketNotResolved.selector);
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);
    }

    function test_CloseResolvedPosition_RevertsNoPosition() public {
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, false)
        );

        vm.expectRevert(NoPosition.selector);
        poolAdmin.closeLostPosition(borrower, TOKEN_ID_YES);
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
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );

        // Redeem: burns 5000 CTF shares, mints 5000 USDC to pool
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);

        // Verify redemption recorded
        (bool redeemed, uint256 totalShares, uint256 usdcReceived) = pool
            .redeemedTokens(TOKEN_ID_YES);
        assertTrue(redeemed);
        assertEq(totalShares, 5_000e6, "All shares redeemed");
        assertEq(usdcReceived, 5_000e6, "1:1 USDC from won CTF");
        assertEq(pool.unsettledRedemptions(), 5_000e6);

        // Settle: borrower's debt = ~2000, proceeds = 5000 → surplus = ~3000
        uint256 borrowerBalBefore = usdc.balanceOf(borrower);
        poolAdmin.settleRedemption(borrower, TOKEN_ID_YES);

        // Position deleted
        (uint256 collateral, uint256 shares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // v16: borrow now reduces initialEquity by extracted amount.
        // depositCollateral: initialEquity = 5000 * 0.80 = 4000.
        // borrow 2000: initialEquity reduced to 2000.
        // surplus ≈ 3000, profit ≈ 1000, fee ≈ 100, user receives ≈ 2900.
        uint256 surplus = usdc.balanceOf(borrower) - borrowerBalBefore;
        assertGt(surplus, 2_850e6, "User receives surplus minus profit fee");
        assertLt(surplus, 2_950e6);
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
        poolAdmin.accrueInterest();

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        assertGt(
            debt,
            5_000e6,
            "Debt exceeds collateral value due to interest"
        );

        // Configure and redeem
        bytes32 conditionId = bytes32(uint256(TOKEN_ID_YES));
        ctf.configureRedemption(conditionId, TOKEN_ID_YES, address(usdc));
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, conditionId, 1);

        // Settle — proceeds (5000) < debt → bad debt
        uint256 totalAssetsBefore = pool.totalAssets();
        poolAdmin.settleRedemption(borrower, TOKEN_ID_YES);

        // Position deleted, bad debt absorbed
        (uint256 collateral, uint256 shares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collateral, 0);
        assertEq(shares, 0);

        // Lenders absorb bad debt
        assertLt(pool.totalAssets(), totalAssetsBefore, "Bad debt socialized");
    }

    function test_RedeemWonCollateral_RevertsNotWon() public {
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, false)
        );

        vm.expectRevert(PredmartPoolExtension.MarketNotResolved.selector);
        poolAdmin.redeemWonCollateral(TOKEN_ID_YES, bytes32(0), 1);
    }

    function test_RedeemWonCollateral_RevertsAlreadyRedeemed() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 5_000e6, 2_000e6, 0.80e18);

        bytes32 conditionId = bytes32(uint256(TOKEN_ID_YES));
        ctf.configureRedemption(conditionId, TOKEN_ID_YES, address(usdc));
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );
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
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );

        vm.expectRevert(PredmartPoolExtension.MarketAlreadyResolved.selector);
        poolAdmin.resolveMarket(
            TOKEN_ID_YES,
            _signResolution(TOKEN_ID_YES, true)
        );
    }

    /*//////////////////////////////////////////////////////////////
             TEST: FUZZ — MATH LIBRARY PROPERTIES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Interpolate_Monotonic(
        uint256 priceA,
        uint256 priceB
    ) public view {
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

        // Rate must be at least BASE_RATE (10%) and at most MAX_RATE (3.17)
        assertGe(rate, 0.10e18, "Rate >= base rate");
        assertLe(rate, 3.17e18 + 0.01e18, "Rate bounded above");
    }

    function testFuzz_CalcPendingInterest_NonNegative(
        uint256 borrowAssets,
        uint256 elapsed,
        uint256 utilization
    ) public pure {
        borrowAssets = bound(borrowAssets, 0, 1e15); // Up to $1B USDC
        elapsed = bound(elapsed, 0, 365.25 days * 10); // Up to 10 years
        utilization = bound(utilization, 0, 1e18);

        (uint256 interest, uint256 reserveShare) = PredmartPoolLib
            .calcPendingInterest(borrowAssets, elapsed, utilization);

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
        uint256 hf = PredmartPoolLib.calcHealthFactor(
            collateral,
            debt,
            price,
            threshold
        );

        // HF should be proportional to collateral and inversely proportional to debt
        uint256 hf2 = PredmartPoolLib.calcHealthFactor(
            collateral * 2,
            debt,
            price,
            threshold
        );
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
        assertEq(
            usdc.balanceOf(lender),
            95_000e6,
            "5K withdrawn from 100K initial balance"
        );
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
        TEST: DEPOSIT COLLATERAL FROM (EIP-1271 signature auth —   H-01)
    //////////////////////////////////////////////////////////////*/

    function test_DepositCollateralFrom_ValidEOASignature() public {
        // EOA `from` signs authorization → any submitter can call depositCollateralFrom
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);

        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline
        );

        // Anyone can submit — authorization is in the signature, not msg.sender
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 2_000e6);
        assertEq(
            poolBorrow.depositCollateralFromNonces(borrower),
            nonce + 1,
            "Nonce consumed"
        );
    }

    function test_DepositCollateralFrom_RevertsInvalidSignature() public {
        // Attacker signs with their own key but sets `from` to victim — should revert
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 attackerKey = 0xA77AC;
        address attacker = vm.addr(attackerKey);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        // Attacker signs, but `from` is the victim (borrower) — signature won't match borrower
        bytes memory wrongSig = _signDepositCollateralFromAuth(
            attackerKey,
            borrower,
            attacker,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline
        );

        vm.prank(attacker);
        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        poolBorrow.depositCollateralFrom(
            borrower,
            attacker,
            TOKEN_ID_YES,
            2_000e6,
            nonce,
            deadline,
            wrongSig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_DepositCollateralFrom_RevertsNonceReplay() public {
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        // First submission succeeds
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        // Replay with same nonce reverts
        vm.expectRevert(PredmartBorrowExtension.InvalidNonce.selector);
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_DepositCollateralFrom_RevertsExpiredDeadline() public {
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        vm.warp(deadline + 1);

        vm.expectRevert(PredmartBorrowExtension.IntentExpired.selector);
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    /// @dev Relayer-submitted deposit charges operationFee in shares (spam protection).
    ///      Event semantic: `CollateralDeposited.amount` = actual position state change (net of fee).
    function test_DepositCollateralFrom_FeeChargedOnRelayCall() public {
        _enableFee();
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        // Price = 0.80 USDC/share → fee = $0.01 / 0.80 = 0.0125 shares = 12_500 (scaled)
        uint256 expectedFee = (uint256(10_000) * 1e18) / 0.80e18;
        if (expectedFee * 0.80e18 < 10_000 * 1e18) expectedFee += 1; // ceiling rounding
        uint256 expectedCredited = 1_000e6 - expectedFee;

        // Event must emit the net credited amount (not the full pre-fee amount)
        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(borrower, TOKEN_ID_YES, expectedCredited);

        vm.prank(relayer);
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, expectedCredited, "Position credited post-fee");
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            expectedFee,
            "Fee accumulated in shares pool"
        );
    }

    /// @dev Direct (non-relay) deposit bypasses the fee — user pays their own gas.
    function test_DepositCollateralFrom_NoFeeOnDirectCall() public {
        _enableFee();
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline
        );

        // Direct call (msg.sender = test contract, not relayer) → no fee
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1_000e6,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(
            collateral,
            1_000e6,
            "Full amount credited - no fee on direct call"
        );
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            0,
            "No fee accumulated"
        );
    }

    /// @dev Dust-sized deposit (amount < fee) is entirely consumed as fee.
    function test_DepositCollateralFrom_DustFeeCap() public {
        _enableFee();
        ctf.mint(borrower, TOKEN_ID_YES, 5_000e6);
        vm.prank(borrower);
        ctf.setApprovalForAll(address(pool), true);

        uint256 nonce = poolBorrow.depositCollateralFromNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        // Tiny deposit: 1000 raw shares (= $0.0008 worth at $0.80 price) — less than $0.01 fee
        bytes memory sig = _signDepositCollateralFromAuth(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            1000,
            nonce,
            deadline
        );

        vm.prank(relayer);
        poolBorrow.depositCollateralFrom(
            borrower,
            borrower,
            TOKEN_ID_YES,
            1000,
            nonce,
            deadline,
            sig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 0, "Dust deposit fully consumed as fee");
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            1000,
            "All shares went to fee pool"
        );
    }

    /*//////////////////////////////////////////////////////////////
       TEST: PARTIAL LIQUIDATION (above water, HF >= 0.95)
    //////////////////////////////////////////////////////////////*/

    function test_Liquidation_FullSeizure_v2() public {
        vm.prank(admin);
        poolAdmin.setPoolCapBps(0);
        _supply(lender, 50_000e6);

        _depositAndBorrow(borrower, TOKEN_ID_YES, 10_000e6, 5_000e6, 0.80e18);

        PredmartOracle.PriceData memory lowPrice = _signPrice(
            TOKEN_ID_YES,
            0.66e18
        );

        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, lowPrice);

        // v2: full seizure — position fully deleted
        (uint256 collAfter, uint256 sharesAfter, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(collAfter, 0, "All collateral seized");
        assertEq(sharesAfter, 0, "All debt cleared");

        // Pending liquidation created
        (address liqAddr, uint256 debt, , ) = pool.pendingLiquidations(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(liqAddr, liquidator, "Liquidator recorded");
        assertGt(debt, 0, "Debt recorded in pending");

        // Liquidator received the shares
        assertEq(
            ctf.balanceOf(liquidator, TOKEN_ID_YES),
            10_000e6,
            "Liquidator received all shares"
        );
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
        uint256 hf = PredmartPoolLib.calcHealthFactor(
            1_000e6,
            0,
            0.80e18,
            0.80e18
        );
        assertEq(hf, type(uint256).max, "Zero debt = max HF");
    }

    /// @dev Fuzz: borrow → full repay should never leave dust shares or create free USDC
    function testFuzz_BorrowRepayRoundtrip_NoDust(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1e6, 2_500e6); // MIN_BORROW to within cap

        _supply(lender, 50_000e6);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            5_000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Borrow
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            borrowAmount,
            nonce,
            deadline
        );
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: borrowAmount,
                nonce: nonce,
                deadline: deadline
            });
        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Accrue some interest (random-ish time)
        vm.warp(block.timestamp + (borrowAmount % 365 days) + 1);

        // Full repay
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        poolAdmin.repay(borrower, TOKEN_ID_YES, type(uint256).max);
        vm.stopPrank();

        // Invariant: no dust shares remain
        (, uint256 sharesAfter, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(sharesAfter, 0, "Full repay must zero shares");

        // Invariant: global tracking is consistent
        assertEq(
            pool.totalBorrowShares(),
            0,
            "Global shares zero after sole borrower repays"
        );
        assertEq(
            pool.totalBorrowAssets(),
            0,
            "Global assets zero after sole borrower repays"
        );
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
        uint256 hf = PredmartPoolLib.calcHealthFactor(
            collateral,
            debt,
            price,
            threshold
        );
        if (hf >= 1e18) return; // Healthy — skip

        (uint256 seizeCollateral, uint256 repayAmount) = PredmartPoolLib
            .calcLiquidation(collateral, debt);

        // v2: always seizes all collateral
        assertEq(seizeCollateral, collateral, "Must seize all collateral");

        // repayAmount equals total debt
        assertEq(repayAmount, debt, "Must repay all debt");
    }

    /*//////////////////////////////////////////////////////////////
                   TEST: POOL-FUNDED FLASH CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: build CloseAuth struct and sign it
    function _buildAndSignCloseAuth(
        uint256 tokenId,
        uint256 price
    )
        internal
        view
        returns (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        )
    {
        uint256 nonce = pool.closeNonces(borrower, tokenId);
        uint256 deadline = block.timestamp + 300;
        auth = PredmartPoolExtension.CloseAuth({
            borrower: borrower,
            allowedTo: safe,
            tokenId: tokenId,
            nonce: nonce,
            deadline: deadline
        });
        sig = _signCloseAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            tokenId,
            nonce,
            deadline
        );
        priceData = _signPrice(tokenId, price);
    }

    function test_flashClose_happyPath() public {
        _supply(lender, 50_000e6);
        uint256 collateral = 1000e6;
        uint256 borrowAmt = 400e6;
        uint256 price = 0.80e18;

        _depositAndBorrow(borrower, TOKEN_ID_YES, collateral, borrowAmt, price);

        uint256 totalAssetsBefore = pool.totalAssets();
        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, price);

        // Flash close — relayer receives shares
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Position deleted
        (uint256 col, uint256 shares, , , , ) = pool.positions(
            borrower,
            TOKEN_ID_YES
        );
        assertEq(col, 0, "Collateral should be 0");
        assertEq(shares, 0, "Borrow shares should be 0");

        // Shares went to relayer, NOT safe
        assertEq(
            ctf.balanceOf(relayer, TOKEN_ID_YES),
            collateral,
            "Shares should be at relayer"
        );
        assertEq(
            ctf.balanceOf(safe, TOKEN_ID_YES),
            0,
            "Safe should have 0 shares"
        );

        // Pending close recorded
        assertEq(
            pool.totalPendingCloses(),
            debt,
            "totalPendingCloses should equal debt"
        );

        // totalAssets unchanged (debt moved to pendingCloses)
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore,
            1,
            "totalAssets invariant"
        );

        // Nonce consumed
        assertEq(
            pool.closeNonces(borrower, TOKEN_ID_YES),
            1,
            "Nonce should be 1"
        );
    }

    function test_flashClose_settleFullRepayment() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsBefore = pool.totalAssets();

        // Flash close
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Simulate CLOB sale: relayer has USDC from selling shares
        uint256 saleProceeds = 790e6; // 1000 shares * 0.79 price (with slippage)
        // V2 split: USDC.e leg covers debt + fee; pUSD leg covers surplus.
        // Here surplus (390) < initialEquity (400) → no profit, fee = 0.
        uint256 expectedSurplus = saleProceeds - debt;
        MockUSDC pusdAt = MockUSDC(0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB);
        uint256 safePusdBefore = pusdAt.balanceOf(safe);

        // Settle
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, debt, expectedSurplus);

        // Pending close cleared
        assertEq(
            pool.totalPendingCloses(),
            0,
            "totalPendingCloses should be 0"
        );

        // Surplus sent to safe in pUSD
        assertEq(
            pusdAt.balanceOf(safe),
            safePusdBefore + expectedSurplus,
            "Safe should receive surplus in pUSD"
        );

        // totalAssets should be approximately same (USDC.e leg = debt, pool nets zero)
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore,
            1,
            "totalAssets invariant after settle"
        );
    }

    function test_flashClose_settleBadDebt() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsBefore = pool.totalAssets();

        // Flash close
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Simulate partial CLOB sale — less than debt
        uint256 saleProceeds = 300e6;
        uint256 expectedBadDebt = debt - saleProceeds;

        // Settle
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, saleProceeds, 0);

        // Pending close cleared
        assertEq(
            pool.totalPendingCloses(),
            0,
            "totalPendingCloses should be 0"
        );

        // No surplus to safe (saleProceeds < debt)
        assertEq(
            usdc.balanceOf(safe),
            50_000e6,
            "Safe should receive no surplus"
        );

        // totalAssets dropped by bad debt amount
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore - expectedBadDebt,
            1,
            "totalAssets should drop by bad debt"
        );
    }

    function test_flashClose_expirePendingClose() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        uint256 totalAssetsBefore = pool.totalAssets();

        // Flash close
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Try to expire before deadline — should fail
        vm.expectRevert(PredmartPoolExtension.CloseNotExpired.selector);
        poolAdmin.expirePendingClose(borrower, TOKEN_ID_YES);

        // Warp past deadline (48 hours)
        vm.warp(block.timestamp + 48 hours + 1);

        // Expire — permissionless, anyone can call
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        poolAdmin.expirePendingClose(borrower, TOKEN_ID_YES);

        // Pending close cleared
        assertEq(
            pool.totalPendingCloses(),
            0,
            "totalPendingCloses should be 0"
        );

        // Full bad debt absorbed
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore - debt,
            1,
            "totalAssets should drop by full debt"
        );
    }

    function test_flashClose_revertUnhealthyPosition() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // Price drops — position becomes unhealthy
        uint256 lowPrice = 0.30e18;

        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,

        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, lowPrice);

        PredmartOracle.PriceData memory lowPriceData = _signPrice(
            TOKEN_ID_YES,
            lowPrice
        );

        vm.expectRevert(PredmartPoolExtension.PositionUnhealthy.selector);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, lowPriceData);
    }

    function test_flashClose_revertDoubleClose() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // First close succeeds
        (
            PredmartPoolExtension.CloseAuth memory auth1,
            bytes memory sig1,
            PredmartOracle.PriceData memory priceData1
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth1, sig1, priceData1);

        // Deposit during pending close should fail
        ctf.mint(borrower, TOKEN_ID_YES, 500e6);
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        vm.expectRevert(PredmartPoolExtension.PositionHasPendingClose.selector);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            500e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Second close on same tokenId should also fail — pending close still exists
        (
            PredmartPoolExtension.CloseAuth memory auth2,
            bytes memory sig2,
            PredmartOracle.PriceData memory priceData2
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.expectRevert(PredmartPoolExtension.PositionHasPendingClose.selector);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth2, sig2, priceData2);
    }

    function test_flashClose_revertZeroDebtPosition() public {
        // Deposit collateral without borrowing
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            500e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Flash close on zero-debt position should revert (use withdrawViaRelay instead)
        uint256 nonce = pool.closeNonces(borrower, TOKEN_ID_YES);
        uint256 deadline = block.timestamp + 300;
        PredmartPoolExtension.CloseAuth memory auth = PredmartPoolExtension
            .CloseAuth({
                borrower: borrower,
                allowedTo: safe,
                tokenId: TOKEN_ID_YES,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signCloseAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            nonce,
            deadline
        );

        vm.expectRevert(NoPosition.selector);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_flashClose_revertWrongSigner() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 nonce = pool.closeNonces(borrower, TOKEN_ID_YES);
        uint256 deadline = block.timestamp + 300;
        PredmartPoolExtension.CloseAuth memory auth = PredmartPoolExtension
            .CloseAuth({
                borrower: borrower,
                allowedTo: safe,
                tokenId: TOKEN_ID_YES,
                nonce: nonce,
                deadline: deadline
            });

        // Sign with wrong key (relayer key instead of borrower key)
        bytes memory badSig = _signCloseAuth(
            relayerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            nonce,
            deadline
        );

        vm.expectRevert(PredmartBorrowExtension.InvalidIntentSignature.selector);
        vm.prank(relayer);
        poolAdmin.initiateClose(
            auth,
            badSig,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
    }

    function test_flashClose_revertExpiredDeadline() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 nonce = pool.closeNonces(borrower, TOKEN_ID_YES);
        uint256 deadline = block.timestamp + 300;
        PredmartPoolExtension.CloseAuth memory auth = PredmartPoolExtension
            .CloseAuth({
                borrower: borrower,
                allowedTo: safe,
                tokenId: TOKEN_ID_YES,
                nonce: nonce,
                deadline: deadline
            });
        bytes memory sig = _signCloseAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            nonce,
            deadline
        );

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.expectRevert(PredmartBorrowExtension.IntentExpired.selector);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    function test_flashClose_revertNotRelayer() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);

        // Call from non-relayer
        vm.expectRevert(NotRelayer.selector);
        vm.prank(borrower);
        poolAdmin.initiateClose(auth, sig, priceData);
    }

    function test_flashClose_totalAssetsInvariant() public {
        _supply(lender, 50_000e6);

        // Create two positions
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);
        ctf.mint(borrower, TOKEN_ID_NO, 2000e6);
        _depositAndBorrow(borrower, TOKEN_ID_NO, 2000e6, 300e6, 0.40e18);

        uint256 totalAssetsBefore = pool.totalAssets();

        // Close first position
        (
            PredmartPoolExtension.CloseAuth memory auth1,
            bytes memory sig1,
            PredmartOracle.PriceData memory priceData1
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth1, sig1, priceData1);

        // totalAssets unchanged after close
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore,
            1,
            "Invariant after first close"
        );

        // Settle first with full proceeds
        uint256 debt1 = pool.totalPendingCloses();
        uint256 surplus1 = 100e6;
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, debt1, surplus1);

        // totalAssets unchanged after settle (surplus leaves pool)
        assertApproxEqAbs(
            pool.totalAssets(),
            totalAssetsBefore,
            1,
            "Invariant after first settle"
        );

        // Second position still active
        (uint256 col2, , , , , ) = pool.positions(borrower, TOKEN_ID_NO);
        assertGt(col2, 0, "Second position should still exist");
    }

    function test_flashClose_settleNoPendingClose() public {
        vm.expectRevert(PredmartPoolExtension.NoPendingClose.selector);
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, 100e6, 0);
    }

    function test_flashClose_settleZeroProceeds() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        // Flash close
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Settle with zero proceeds (complete failure to sell)
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, 0, 0);

        // Full bad debt
        assertEq(
            pool.totalPendingCloses(),
            0,
            "totalPendingCloses should be 0"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     OPERATION FEE TESTS (v1.3.0)
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: enable the $0.01 operation fee via admin
    function _enableFee() internal {
        vm.prank(admin);
        poolAdmin.setOperationFee(10_000); // $0.01 USDC
    }

    function test_borrowViaRelay_deductsFee() public {
        _supply(lender, 50_000e6);
        _enableFee();

        // Deposit collateral
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 borrowerBalBefore = usdc.balanceOf(borrower);

        // Borrow $400 via relay
        uint256 borrowAmt = 400e6;
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            borrowAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: borrowAmt,
                nonce: nonce,
                deadline: deadline
            });

        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        // User receives $400 - $0.01 = $399.99
        uint256 received = usdc.balanceOf(borrower) - borrowerBalBefore;
        assertEq(
            received,
            borrowAmt - 10_000,
            "Borrower should receive amount minus fee"
        );

        // Fee went to operationFeePool
        assertEq(
            pool.operationFeePool(),
            10_000,
            "operationFeePool should be $0.01"
        );
    }

    function test_borrowViaRelay_zeroFee() public {
        _supply(lender, 50_000e6);
        // Don't enable fee — default 0

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 borrowerBalBefore = usdc.balanceOf(borrower);
        uint256 borrowAmt = 400e6;
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signBorrowIntent(
            borrowerPrivateKey,
            borrower,
            TOKEN_ID_YES,
            borrowAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension
            .BorrowIntent({
                borrower: borrower,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                amount: borrowAmt,
                nonce: nonce,
                deadline: deadline
            });

        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        uint256 received = usdc.balanceOf(borrower) - borrowerBalBefore;
        assertEq(received, borrowAmt, "Full amount when fee is 0");
        assertEq(pool.operationFeePool(), 0, "No fee collected");
    }

    function test_withdrawViaRelay_deductsShares() public {
        _supply(lender, 50_000e6);
        _enableFee();
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 withdrawAmt = 100e6; // 100 shares
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            withdrawAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: withdrawAmt,
                nonce: nonce,
                deadline: deadline
            });

        uint256 borrowerSharesBefore = ctf.balanceOf(borrower, TOKEN_ID_YES);

        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        // Fee in shares: $0.01 / $0.80 = 0.0125 shares = 12500 raw (rounded up)
        uint256 expectedFeeShares = 12_500; // 10000 * 1e18 / 0.80e18 = 12500
        uint256 received = ctf.balanceOf(borrower, TOKEN_ID_YES) -
            borrowerSharesBefore;
        assertEq(
            received,
            withdrawAmt - expectedFeeShares,
            "User gets shares minus fee"
        );
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            expectedFeeShares,
            "Fee shares tracked"
        );
    }

    function test_withdrawViaRelay_noDebt_stillCharges() public {
        _enableFee();

        // Deposit collateral, no borrow
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        uint256 withdrawAmt = 500e6;
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            withdrawAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: withdrawAmt,
                nonce: nonce,
                deadline: deadline
            });

        uint256 borrowerSharesBefore = ctf.balanceOf(borrower, TOKEN_ID_YES);

        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.50e18));

        // Fee in shares: $0.01 / $0.50 = 0.02 shares = 20000 raw
        uint256 expectedFeeShares = 20_000;
        uint256 received = ctf.balanceOf(borrower, TOKEN_ID_YES) -
            borrowerSharesBefore;
        assertEq(
            received,
            withdrawAmt - expectedFeeShares,
            "Fee charged even with no debt"
        );
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            expectedFeeShares,
            "Fee shares tracked"
        );
    }

    function test_withdrawViaRelay_lowPriceTakesAll() public {
        _enableFee();

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(
            borrower,
            TOKEN_ID_YES,
            1000e6,
            _signPrice(TOKEN_ID_YES, 0.80e18)
        );
        vm.stopPrank();

        // Withdraw 1 share at $0.005 → fee = 2 shares > 1 share → entire withdrawal taken as fee
        uint256 withdrawAmt = 1e6;
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            withdrawAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: withdrawAmt,
                nonce: nonce,
                deadline: deadline
            });

        uint256 borrowerSharesBefore = ctf.balanceOf(borrower, TOKEN_ID_YES);

        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.005e18));

        // User receives 0 shares — entire withdrawal consumed by fee (spam protection)
        uint256 received = ctf.balanceOf(borrower, TOKEN_ID_YES) -
            borrowerSharesBefore;
        assertEq(received, 0, "User gets nothing - fee took everything");
        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            withdrawAmt,
            "All shares taken as fee"
        );
    }

    function test_leverageDeposit_feeOnFirstBorrowOnly() public {
        _supply(lender, 50_000e6);
        _enableFee();

        // Mint shares to relayer for leverage deposits (H-03 fix: deposits from `allowedFrom` require
        // the Safe's signature; this test focuses on fee logic so we use the relayer's own shares)
        ctf.mint(relayer, TOKEN_ID_YES, 5000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        uint256 maxBorrow = 2000e6;
        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey,
            borrower,
            safe,
            TOKEN_ID_YES,
            maxBorrow,
            nonce,
            deadline
        );
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: maxBorrow,
                nonce: nonce,
                deadline: deadline
            });
        PredmartOracle.PriceData memory priceData = _signPrice(
            TOKEN_ID_YES,
            0.80e18
        );

        // Step 1: deposit + borrow (first borrow → fee charged)
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 1000e6, 500e6),
            priceData
        );
        assertEq(
            pool.operationFeePool(),
            10_000,
            "Fee charged on first borrow"
        );

        // Step 2: deposit + borrow (subsequent → no fee)
        vm.prank(relayer);
        poolBorrow.leverageDeposit(
            auth,
            sig,
            "",
            _ldd(relayer, relayer, 500e6, 200e6),
            priceData
        );
        assertEq(
            pool.operationFeePool(),
            10_000,
            "No additional fee on second borrow"
        );
    }

    function test_settleClose_profitFee_v2() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // equity = 1000*0.80 - 400 = 400
        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);

        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Sell at higher price to generate profit
        uint256 saleProceeds = 900e6; // 1000 shares * $0.90 → surplus = 500
        uint256 surplus = saleProceeds - debt;
        uint256 expectedProfit = surplus - 400e6; // initialEquity = 400
        uint256 expectedFee = expectedProfit / 10; // 10% (7% pool + 3% protocol)
        uint256 surplusAfterFee = surplus - expectedFee;
        // V2 split: USDC.e leg = debt + fee; pUSD leg = surplus net of fee.
        MockUSDC pusdAt = MockUSDC(0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB);
        uint256 safePusdBefore = pusdAt.balanceOf(safe);

        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, debt + expectedFee, surplusAfterFee);

        // User receives surplus net of fee, in pUSD
        assertApproxEqAbs(
            pusdAt.balanceOf(safe) - safePusdBefore,
            surplusAfterFee,
            1,
            "User receives surplus minus 10% profit fee in pUSD"
        );
        assertApproxEqAbs(
            pool.protocolFeePool(),
            (expectedProfit * 3) / 100,
            1,
            "Protocol receives 3% of profit"
        );
    }

    function test_settleClose_feeSkippedIfProceedsTooLow() public {
        _supply(lender, 50_000e6);
        _enableFee();
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        uint256 feePoolBefore = pool.operationFeePool(); // 10000 from borrow

        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Settle with proceeds less than fee ($0.005 < $0.01)
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, 5_000, 0);

        // Fee not deducted from settleClose (proceeds too low)
        assertEq(
            pool.operationFeePool(),
            feePoolBefore,
            "No additional fee when proceeds < fee"
        );
    }

    function test_liquidate_noFee() public {
        _supply(lender, 50_000e6);
        _enableFee();
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // Price drops → position unhealthy
        uint256 feePoolBefore = pool.operationFeePool();
        vm.prank(liquidator);
        poolAdmin.liquidate(
            borrower,
            TOKEN_ID_YES,
            _signPrice(TOKEN_ID_YES, 0.50e18)
        );

        // No fee charged for liquidation
        assertEq(
            pool.operationFeePool(),
            feePoolBefore,
            "Liquidation should not charge fee"
        );
    }

    function test_setOperationFee_onlyAdmin() public {
        vm.prank(admin);
        poolAdmin.setOperationFee(50_000);
        assertEq(pool.operationFee(), 50_000, "Admin can set fee");

        vm.prank(borrower);
        vm.expectRevert(NotAdmin.selector);
        poolAdmin.setOperationFee(100_000);
    }

    function test_withdrawOperationFees() public {
        _supply(lender, 50_000e6);
        _enableFee();

        // Generate some fees via borrow
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);
        assertEq(pool.operationFeePool(), 10_000, "Fee collected");

        uint256 adminBalBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        poolAdmin.withdrawOperationFees(10_000);

        assertEq(pool.operationFeePool(), 0, "Pool drained");
        assertEq(
            usdc.balanceOf(admin) - adminBalBefore,
            10_000,
            "Admin received fees"
        );
    }

    function test_withdrawFeeShares() public {
        _supply(lender, 50_000e6);
        _enableFee();
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // Generate share fees via withdrawal
        uint256 withdrawAmt = 100e6;
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey,
            borrower,
            borrower,
            TOKEN_ID_YES,
            withdrawAmt,
            nonce,
            deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension
            .WithdrawIntent({
                borrower: borrower,
                to: borrower,
                tokenId: TOKEN_ID_YES,
                amount: withdrawAmt,
                nonce: nonce,
                deadline: deadline
            });
        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        uint256 feeShares = pool.feeSharesAccumulated(TOKEN_ID_YES);
        assertTrue(feeShares > 0, "Fee shares exist");

        // Admin withdraws fee shares
        uint256 relayerSharesBefore = ctf.balanceOf(relayer, TOKEN_ID_YES);
        vm.prank(admin);
        poolAdmin.withdrawFeeShares(TOKEN_ID_YES, feeShares, relayer);

        assertEq(
            pool.feeSharesAccumulated(TOKEN_ID_YES),
            0,
            "Accumulator cleared"
        );
        assertEq(
            ctf.balanceOf(relayer, TOKEN_ID_YES) - relayerSharesBefore,
            feeShares,
            "Relayer received shares"
        );
    }

    function test_operationFeePool_excludedFromLendableCash() public {
        _supply(lender, 50_000e6);
        _enableFee();

        uint256 totalAssetsBefore = pool.totalAssets();

        // Borrow → generates fee in operationFeePool
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // totalAssets should NOT include the $0.01 fee (it's reserved for relayer, not lenders)
        // totalAssets = cash + borrows - reserves - unsettled - operationFeePool
        uint256 totalAssetsAfter = pool.totalAssets();

        // The fee pool should be excluded — totalAssets tracks lender value, not relayer fees
        assertEq(pool.operationFeePool(), 10_000, "Fee collected");
        // totalAssets should be same as if no fee existed (the USDC stays in contract either way)
        assertApproxEqAbs(
            totalAssetsAfter,
            totalAssetsBefore,
            1,
            "Fee pool excluded from totalAssets"
        );
    }

    function test_totalReserves_onlyInterest() public {
        _supply(lender, 50_000e6);
        _enableFee();

        uint256 reservesBefore = pool.totalReserves();

        // Borrow and generate fee
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);

        // Fee should go to operationFeePool, NOT totalReserves
        assertEq(
            pool.totalReserves(),
            reservesBefore,
            "totalReserves unchanged by borrow fee"
        );
        assertEq(
            pool.operationFeePool(),
            10_000,
            "Fee went to operationFeePool"
        );

        // Fast-forward to accrue interest
        vm.warp(block.timestamp + 365 days);
        poolAdmin.accrueInterest();

        // NOW totalReserves should increase (from interest, not from fees)
        assertTrue(
            pool.totalReserves() > reservesBefore,
            "Interest accrual adds to totalReserves"
        );
    }

    /*//////////////////////////////////////////////////////////////
                  TEST: initialEquity REDUCTION (v16 fix)
    //////////////////////////////////////////////////////////////*/

    /// @notice After deposit, a subsequent borrow that extracts USDC reduces initialEquity.
    function test_initialEquity_reducedOnSubsequentBorrow() public {
        _supply(lender, 50_000e6);

        // Deposit 1000 shares at $0.80 → initialEquity = 800e6
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        (, , , , uint256 eqAfterDeposit, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eqAfterDeposit, 800e6, "Deposit sets initialEquity to USDC value");

        // Simple borrow $300 → initialEquity reduced by 300 to 500
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension.BorrowIntent({
            borrower: borrower, recipient: borrower, tokenId: TOKEN_ID_YES, amount: 300e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 300e6, nonce, deadline);
        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        (, , , , uint256 eqAfterBorrow, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eqAfterBorrow, 500e6, "Borrow reduced initialEquity by extracted amount");
    }

    /// @notice Two successive borrows on the same position both reduce initialEquity.
    function test_initialEquity_reducedOnEachBorrow() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1_000e6, 200e6, 0.80e18);
        // After: initialEquity = 800 - 200 = 600

        (, , , , uint256 eqAfterFirst, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eqAfterFirst, 600e6, "First borrow: initialEquity reduced by 200");

        // Second borrow $150
        uint256 nonce = pool.borrowNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.BorrowIntent memory intent = PredmartBorrowExtension.BorrowIntent({
            borrower: borrower, recipient: borrower, tokenId: TOKEN_ID_YES, amount: 150e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signBorrowIntent(borrowerPrivateKey, borrower, TOKEN_ID_YES, 150e6, nonce, deadline);
        vm.prank(relayer);
        poolBorrow.borrowViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        (, , , , uint256 eqAfterSecond, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eqAfterSecond, 450e6, "Second borrow: initialEquity reduced by 150 more");
    }

    /// @notice initialEquity is reduced by borrow up to the LTV ceiling.
    function test_initialEquity_borrowReducesUpToLTV() public {
        _supply(lender, 50_000e6);
        // Deposit 1000 at $1.00 → initialEquity = 1000, LTV 75% → max borrow 750.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1_000e6, 700e6, 1.00e18);
        (, , , , uint256 eq, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eq, 300e6, "Borrow of 700 from initialEquity 1000 leaves 300");
    }

    /// @notice Withdrawing collateral reduces initialEquity by USDC value of withdrawn shares.
    function test_initialEquity_reducedOnWithdraw() public {
        _supply(lender, 50_000e6);

        // Deposit 1000 shares at $0.80 → initialEquity = 800. No debt.
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        // Withdraw 200 shares via relay (worth $160 at $0.80).
        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey, borrower, borrower, TOKEN_ID_YES, 200e6, nonce, deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension.WithdrawIntent({
            borrower: borrower, to: borrower, tokenId: TOKEN_ID_YES, amount: 200e6, nonce: nonce, deadline: deadline
        });
        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        (, , , , uint256 eq, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eq, 640e6, "Withdraw reduced initialEquity by withdrawn USDC value");
    }

    /// @notice End-to-end: simple borrow after deposit changes profit fee correctly on close.
    function test_initialEquity_profitFeeCorrectAfterBorrow() public {
        _supply(lender, 50_000e6);
        // Deposit 1000 at $0.80 → initialEquity = 800. Borrow 400 → equity = 400.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1_000e6, 400e6, 0.80e18);

        uint256 debt = pool.getPositionDebt(borrower, TOKEN_ID_YES);
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);

        // Sell at $0.90: saleProceeds = 900, surplus = 500.
        // After fix: equity = 400, profit = 100, fee = 10 (7 pool + 3 protocol), user gets 490.
        uint256 expectedSurplusBeforeFee = 900e6 - debt;
        uint256 expectedProfit = expectedSurplusBeforeFee - 400e6;
        uint256 expectedFeeTotal = expectedProfit / 10;
        uint256 surplusAfterFee = expectedSurplusBeforeFee - expectedFeeTotal;
        MockUSDC pusdAt = MockUSDC(0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB);
        uint256 safePusdBefore = pusdAt.balanceOf(safe);
        uint256 protoBefore = pool.protocolFeePool();
        vm.prank(relayer);
        poolAdmin.settleClose(borrower, TOKEN_ID_YES, debt + expectedFeeTotal, surplusAfterFee);

        assertApproxEqAbs(
            pusdAt.balanceOf(safe) - safePusdBefore,
            surplusAfterFee,
            1,
            "User receives surplus minus 10% profit fee in pUSD"
        );
        assertApproxEqAbs(
            pool.protocolFeePool() - protoBefore,
            (expectedProfit * 3) / 100, // 3% protocol
            1,
            "Protocol receives 3% of profit"
        );
    }

    /*//////////////////////////////////////////////////////////////
            TEST: leverageDeposit deposit-only replay (v16 fix)
    //////////////////////////////////////////////////////////////*/

    /// @notice First deposit-only call against a fresh authHash succeeds and adds collateral.
    function test_leverageDepositOnly_firstCallSucceeds() public {
        _supply(lender, 50_000e6);
        ctf.mint(relayer, TOKEN_ID_YES, 1_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 100e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension.LeverageAuth({
            borrower: borrower, allowedFrom: safe, recipient: borrower, tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline
        );

        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 500e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));

        (uint256 collateral, , , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 600e6, "100 initial + 500 deposited");
    }

    /// @notice Second deposit-only call against the same authHash reverts AuthAlreadyUsed.
    function test_leverageDepositOnly_replayReverts() public {
        _supply(lender, 50_000e6);
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 100e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension.LeverageAuth({
            borrower: borrower, allowedFrom: safe, recipient: borrower, tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline
        );

        // First deposit-only call succeeds.
        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 500e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));

        // Second deposit-only call with the same auth must revert.
        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.AuthAlreadyUsed.selector);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 500e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /// @notice Deposit-only call after a borrow has been formalized reverts AuthAlreadyUsed.
    function test_leverageDepositOnly_revertsAfterBorrow() public {
        _supply(lender, 50_000e6);
        ctf.mint(relayer, TOKEN_ID_YES, 3_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension.LeverageAuth({
            borrower: borrower, allowedFrom: safe, recipient: borrower, tokenId: TOKEN_ID_YES,
            maxBorrow: 2_000e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 2_000e6, nonce, deadline
        );

        // First call: deposit + borrow combined.
        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 1_000e6, 500e6), _signPrice(TOKEN_ID_YES, 0.80e18));

        // Subsequent deposit-only call with the same auth must revert.
        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.AuthAlreadyUsed.selector);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 500e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /// @notice Path 1 (pre-deposit then deposit+borrow) still works under the new gate.
    function test_leverageDepositOnly_path1StillWorks() public {
        _supply(lender, 50_000e6);
        ctf.mint(relayer, TOKEN_ID_YES, 2_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 100e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension.LeverageAuth({
            borrower: borrower, allowedFrom: safe, recipient: borrower, tokenId: TOKEN_ID_YES,
            maxBorrow: 1_000e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 1_000e6, nonce, deadline
        );

        // Pre-deposit: deposit-only.
        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 500e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));

        // Combined deposit + borrow with the same auth — must succeed (gate skipped because borrowAmount > 0).
        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 1_000e6, 500e6), _signPrice(TOKEN_ID_YES, 0.80e18));

        (uint256 collateral, uint256 borrowShares, , , , ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(collateral, 1_600e6, "100 initial + 500 pre + 1000 main = 1600");
        assertGt(borrowShares, 0, "Borrow formalized");
    }

    /// @notice Combined deposit+borrow path is not gated by the deposit-only flag,
    /// and a subsequent deposit-only call still reverts (caught by the borrow-already-used branch).
    function test_leverageDepositOnly_combinedCallNotGated() public {
        _supply(lender, 50_000e6);
        ctf.mint(relayer, TOKEN_ID_YES, 1_000e6);
        vm.prank(relayer);
        ctf.setApprovalForAll(address(pool), true);

        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.leverageNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension.LeverageAuth({
            borrower: borrower, allowedFrom: safe, recipient: borrower, tokenId: TOKEN_ID_YES,
            maxBorrow: 2_000e6, nonce: nonce, deadline: deadline
        });
        bytes memory sig = _signLeverageAuth(
            borrowerPrivateKey, borrower, safe, TOKEN_ID_YES, 2_000e6, nonce, deadline
        );

        // Combined call succeeds.
        vm.prank(relayer);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 1_000e6, 500e6), _signPrice(TOKEN_ID_YES, 0.80e18));

        // A follow-up deposit-only call reverts because borrow has already been recorded.
        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.AuthAlreadyUsed.selector);
        poolBorrow.leverageDeposit(auth, sig, "", _ldd(relayer, relayer, 100e6, 0), _signPrice(TOKEN_ID_YES, 0.80e18));
    }

    /// @notice Smaller withdraw with relay reduces initialEquity proportional to withdrawn value.
    function test_initialEquity_smallerWithdraw() public {
        _supply(lender, 50_000e6);
        vm.startPrank(borrower);
        ctf.setApprovalForAll(address(pool), true);
        poolAdmin.depositCollateral(borrower, TOKEN_ID_YES, 1_000e6, _signPrice(TOKEN_ID_YES, 0.80e18));
        vm.stopPrank();

        uint256 nonce = pool.withdrawNonces(borrower);
        uint256 deadline = block.timestamp + 300;
        bytes memory sig = _signWithdrawIntent(
            borrowerPrivateKey, borrower, borrower, TOKEN_ID_YES, 100e6, nonce, deadline
        );
        PredmartBorrowExtension.WithdrawIntent memory intent = PredmartBorrowExtension.WithdrawIntent({
            borrower: borrower, to: borrower, tokenId: TOKEN_ID_YES, amount: 100e6, nonce: nonce, deadline: deadline
        });
        vm.prank(relayer);
        poolBorrow.withdrawViaRelay(intent, sig, _signPrice(TOKEN_ID_YES, 0.80e18));

        (, , , , uint256 eq, ) = pool.positions(borrower, TOKEN_ID_YES);
        assertEq(eq, 720e6, "100 shares * $0.80 = 80 reduction; 800 - 80 = 720");
    }

    /*//////////////////////////////////////////////////////////////
       TEST: settleLiquidation fee shortfall visibility (Finding #7)
    //////////////////////////////////////////////////////////////*/

    /// @notice When the liquidator fee exceeds available surplus, the pool nets less
    /// than `debt`. The fix emits BadDebtAbsorbed for the shortfall so monitoring can
    /// track it consistently with the insolvent path.
    function test_settleLiquidation_FeeShortfall_EmitsBadDebt() public {
        _supply(lender, 50_000e6);
        // Deposit 1000 shares at $0.80 (collateral value $800). LTV at 0.80 = 70% → max borrow $560.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1_000e6, 500e6, 0.80e18);

        // Crash price to $0.50 (collateral value $500, max borrow $300 → underwater).
        PredmartOracle.PriceData memory crashPrice = _signPrice(TOKEN_ID_YES, 0.50e18);
        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, crashPrice);

        // _depositAndBorrow borrows 500e6 immediately; pendingLiquidations.debt at this
        // instant ≈ 500e6 + accrued (negligible — same block).
        uint256 approxDebt = 500e6;
        uint256 liquidatorFee = (approxDebt * 5) / 100; // 5% of debt = 25e6

        // Choose saleProceeds so that surplus (proceeds - debt) is LESS than the fee.
        // Set surplus = 5e6 → fee 25e6 > surplus 5e6 → shortfall = 20e6.
        uint256 saleProceeds = approxDebt + 5e6;
        uint256 expectedShortfall = liquidatorFee - 5e6; // 20e6

        vm.prank(liquidator);
        usdc.approve(address(pool), saleProceeds);

        vm.expectEmit(true, true, false, true);
        emit BadDebtAbsorbed(borrower, TOKEN_ID_YES, expectedShortfall);

        vm.prank(liquidator);
        poolAdmin.settleLiquidation(borrower, TOKEN_ID_YES, saleProceeds);
    }

    /// @notice When surplus exceeds the liquidator fee, the pool is whole and no
    /// BadDebtAbsorbed event should fire. Sanity check that the new branch only
    /// triggers in the actual shortfall window.
    function test_settleLiquidation_NoShortfall_NoBadDebt() public {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1_000e6, 500e6, 0.80e18);

        PredmartOracle.PriceData memory crashPrice = _signPrice(TOKEN_ID_YES, 0.50e18);
        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, crashPrice);

        uint256 approxDebt = 500e6;
        // Choose saleProceeds so surplus comfortably exceeds the 5% fee.
        // surplus = 100e6, fee = 25e6 → no shortfall.
        uint256 saleProceeds = approxDebt + 100e6;

        vm.prank(liquidator);
        usdc.approve(address(pool), saleProceeds);

        // Record logs and verify no BadDebtAbsorbed event was emitted.
        vm.recordLogs();
        vm.prank(liquidator);
        poolAdmin.settleLiquidation(borrower, TOKEN_ID_YES, saleProceeds);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 badDebtSig = keccak256("BadDebtAbsorbed(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != badDebtSig,
                "BadDebtAbsorbed should NOT fire when surplus exceeds liquidator fee"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
              ATOMIC-EXECUTE LEVERAGE MODULE (v17)
    //////////////////////////////////////////////////////////////*/

    function _readLeverageModule() internal view returns (address) {
        return pool.leverageModule();
    }
    function _readPendingLeverageModule() internal view returns (address) {
        return pool.pendingLeverageModule();
    }

    function test_SetLeverageModule_Instant_WhenUnsetAndTimelockOff() public {
        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);
        assertEq(_readLeverageModule(), mod);
    }

    function test_SetLeverageModule_Reverts_WhenTimelockActiveAndAlreadySet() public {
        address mod1 = makeAddr("module1");
        address mod2 = makeAddr("module2");

        vm.prank(admin);
        poolAdmin.setLeverageModule(mod1);

        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);

        vm.prank(admin);
        vm.expectRevert(TimelockNotReady.selector);
        poolAdmin.setLeverageModule(mod2);
    }

    function test_ProposeAndExecuteLeverageModule_AfterTimelock() public {
        address mod1 = makeAddr("module1");
        address mod2 = makeAddr("module2");

        vm.prank(admin);
        poolAdmin.setLeverageModule(mod1);

        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);

        vm.prank(admin);
        poolAdmin.proposeLeverageModule(mod2);

        // Cannot execute before timelock elapses
        vm.prank(admin);
        vm.expectRevert(TimelockNotReady.selector);
        poolAdmin.executeLeverageModule();

        vm.warp(block.timestamp + 6 hours + 1);

        vm.prank(admin);
        poolAdmin.executeLeverageModule();
        assertEq(_readLeverageModule(), mod2);
    }

    function test_CancelPendingLeverageModule_Clears() public {
        address mod1 = makeAddr("module1");
        address mod2 = makeAddr("module2");

        vm.prank(admin);
        poolAdmin.setLeverageModule(mod1);

        vm.prank(admin);
        poolAdmin.activateTimelock(6 hours);

        vm.prank(admin);
        poolAdmin.proposeLeverageModule(mod2);
        assertEq(_readPendingLeverageModule(), mod2);

        vm.prank(admin);
        poolAdmin.cancelPendingLeverageModule();
        assertEq(_readPendingLeverageModule(), address(0));
    }

    function test_PullUsdcForLeverage_RevertsForNonModule() public {
        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: 0,
                deadline: block.timestamp + 300
            });

        // Anyone-but-module call must revert.
        vm.prank(relayer);
        vm.expectRevert(PredmartBorrowExtension.NotLeverageModule.selector);
        poolBorrow.pullUsdcForLeverage(auth, 1_000e6, 0);
    }

    function test_PullUsdcForLeverage_HappyPath_AdvanceOnly() public {
        _supply(lender, 50_000e6);

        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        uint256 nonceBefore = pool.leverageNonces(borrower);
        uint256 relayerBefore = usdc.balanceOf(relayer);

        // Module triggers advance-only call (userAmount=0).
        vm.prank(mod);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);

        // Pool advanced (1_000e6 - operationFee) USDC to relayer.
        // operationFee defaults to 0 in the test fixture unless set.
        assertEq(usdc.balanceOf(relayer), relayerBefore + 1_000e6 - poolAdmin.operationFee(), "relayer received advance");
        assertEq(pool.leverageNonces(borrower), nonceBefore + 1, "nonce consumed");
    }

    function test_PullUsdcForLeverage_ExceedsMaxBorrow_Reverts() public {
        _supply(lender, 50_000e6);

        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 1_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        // userAmount + advanceAmount > maxBorrow → revert
        vm.prank(mod);
        vm.expectRevert(PredmartBorrowExtension.ExceedsBorrowBudget.selector);
        poolBorrow.pullUsdcForLeverage(auth, 600e6, 600e6);
    }

    function test_PullUsdcForLeverage_ExpiredDeadline_Reverts() public {
        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: 0,
                deadline: block.timestamp - 1
            });

        vm.prank(mod);
        vm.expectRevert(PredmartPoolExtension.IntentExpired.selector);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);
    }

    function test_InitializeV19_WiresExtensionsModuleAndSelectorRouting() public {
        // initializeV19 must atomically: rotate the lifecycle extension, set the
        // leverage module, and populate the selector → extension routing table for
        // both extensions. Reinitializer-gated, so callable only via upgradeToAndCall.
        PredmartPoolExtension newPoolExt = new PredmartPoolExtension();
        PredmartBorrowExtension newBorrowExt = new PredmartBorrowExtension();
        PredmartLendingPool newImpl = new PredmartLendingPool();
        address newMod = makeAddr("newModuleV19");

        bytes4[] memory poolSelectors = new bytes4[](0);
        bytes4[] memory borrowSelectors = new bytes4[](2);
        borrowSelectors[0] = PredmartBorrowExtension.borrowViaRelay.selector;
        borrowSelectors[1] = PredmartBorrowExtension.leverageDeposit.selector;

        bytes memory initData = abi.encodeWithSignature(
            "initializeV19(address,address,address,bytes4[],bytes4[])",
            address(newPoolExt),
            address(newBorrowExt),
            newMod,
            poolSelectors,
            borrowSelectors
        );

        vm.prank(admin);
        // initializeV19 is reinitializer(19); the harness has already crossed that
        // version via prior setExtensionSelectors bootstrap, so a second invocation
        // would revert. Deploy a fresh proxy to exercise the upgrade path cleanly.
        PredmartLendingPool freshImpl = new PredmartLendingPool();
        bytes memory freshInit = abi.encodeWithSignature("initialize(address)", admin);
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), freshInit);
        PredmartLendingPool freshPool = PredmartLendingPool(address(freshProxy));

        vm.prank(admin);
        freshPool.upgradeToAndCall(address(newImpl), initData);

        assertEq(freshPool.extension(), address(newPoolExt), "pool extension wired");
        assertEq(
            freshPool.extensionForSelector(borrowSelectors[0]),
            address(newBorrowExt),
            "borrowViaRelay routed"
        );
        assertEq(
            freshPool.extensionForSelector(borrowSelectors[1]),
            address(newBorrowExt),
            "leverageDeposit routed"
        );
    }

    /*//////////////////////////////////////////////////////////////
              EXPIRE PERMISSIONS — RELAYER / LIQUIDATOR / ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: build a flash-close auth + sig + price tuple, run initiateClose,
    ///      and return the resulting (borrower, tokenId) pair so tests can immediately
    ///      operate on the resulting pendingClose slot.
    function _setupPendingClose() internal returns (address, uint256) {
        _supply(lender, 50_000e6);
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 400e6, 0.80e18);
        (
            PredmartPoolExtension.CloseAuth memory auth,
            bytes memory sig,
            PredmartOracle.PriceData memory priceData
        ) = _buildAndSignCloseAuth(TOKEN_ID_YES, 0.80e18);
        vm.prank(relayer);
        poolAdmin.initiateClose(auth, sig, priceData);
        return (borrower, TOKEN_ID_YES);
    }

    function test_ExpirePendingClose_RelayerInstant() public {
        (address b, uint256 tid) = _setupPendingClose();

        // BEFORE deadline — relayer can expire instantly
        vm.prank(relayer);
        poolAdmin.expirePendingClose(b, tid);

        // Slot cleared
        (,,, uint256 deadline,) = poolAdmin.pendingCloses(b, tid);
        assertEq(deadline, 0, "pendingClose cleared");
    }

    function test_ExpirePendingClose_AdminInstant() public {
        (address b, uint256 tid) = _setupPendingClose();

        vm.prank(admin);
        poolAdmin.expirePendingClose(b, tid);

        (,,, uint256 deadline,) = poolAdmin.pendingCloses(b, tid);
        assertEq(deadline, 0);
    }

    function test_ExpirePendingClose_RandomCaller_StillBlockedBeforeDeadline() public {
        (address b, uint256 tid) = _setupPendingClose();

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectRevert(PredmartPoolExtension.CloseNotExpired.selector);
        poolAdmin.expirePendingClose(b, tid);
    }

    function test_ExpirePendingClose_PermissionlessAfterDeadline() public {
        (address b, uint256 tid) = _setupPendingClose();

        vm.warp(block.timestamp + 48 hours + 1);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        poolAdmin.expirePendingClose(b, tid);

        (,,, uint256 deadline,) = poolAdmin.pendingCloses(b, tid);
        assertEq(deadline, 0);
    }

    /// @dev Helper: trigger a liquidation that creates a pendingLiquidation slot.
    function _setupPendingLiquidation() internal returns (address, uint256) {
        _supply(lender, 50_000e6);
        // Healthy at $0.80 (LTV ~70% → max ≈$560), borrow $500 well under cap.
        _depositAndBorrow(borrower, TOKEN_ID_YES, 1000e6, 500e6, 0.80e18);

        // Crash to $0.10 (LTV ~2%) → position is far underwater
        uint256 crashPrice = 0.10e18;
        PredmartOracle.PriceData memory priceData = _signPrice(TOKEN_ID_YES, crashPrice);

        vm.prank(liquidator);
        poolAdmin.liquidate(borrower, TOKEN_ID_YES, priceData);
        return (borrower, TOKEN_ID_YES);
    }

    function test_ExpirePendingLiquidation_LiquidatorInstant() public {
        (address b, uint256 tid) = _setupPendingLiquidation();

        vm.prank(liquidator);
        poolAdmin.expirePendingLiquidation(b, tid);

        (address liq, , , ) = poolAdmin.pendingLiquidations(b, tid);
        assertEq(liq, address(0), "pendingLiquidation cleared");
    }

    function test_ExpirePendingLiquidation_AdminInstant() public {
        (address b, uint256 tid) = _setupPendingLiquidation();

        vm.prank(admin);
        poolAdmin.expirePendingLiquidation(b, tid);

        (address liq, , , ) = poolAdmin.pendingLiquidations(b, tid);
        assertEq(liq, address(0));
    }

    function test_ExpirePendingLiquidation_RandomCaller_BlockedBefore48h() public {
        (address b, uint256 tid) = _setupPendingLiquidation();

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectRevert(PredmartPoolExtension.TooEarly.selector);
        poolAdmin.expirePendingLiquidation(b, tid);
    }

    function test_ExpirePendingLiquidation_PermissionlessAfter48h() public {
        (address b, uint256 tid) = _setupPendingLiquidation();

        vm.warp(block.timestamp + 48 hours + 1);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        poolAdmin.expirePendingLiquidation(b, tid);

        (address liq, , , ) = poolAdmin.pendingLiquidations(b, tid);
        assertEq(liq, address(0));
    }

    /// @dev expireAdvance: relayer-instant path is the V18 addition. We simulate a
    ///      pending advance by calling pullUsdcForLeverage via the module flow,
    ///      then verify relayer can expire the slot before the 48h timer.
    function test_ExpireAdvance_RelayerInstant() public {
        _supply(lender, 50_000e6);

        // Wire the new leverage module (test fixture mints role)
        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        vm.prank(mod);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);

        bytes32 authHash = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x01),
                _domainSeparator(),
                keccak256(abi.encode(
                    LEVERAGE_AUTH_TYPEHASH,
                    auth.borrower, auth.allowedFrom, auth.recipient, auth.tokenId,
                    auth.maxBorrow, auth.nonce, auth.deadline
                ))
            )
        );

        // BEFORE 48h — relayer can expire instantly
        vm.prank(relayer);
        poolAdmin.expireAdvance(authHash);

        assertEq(poolAdmin.pendingAdvances(authHash), 0, "advance cleared");
    }

    function test_ExpireAdvance_RandomCaller_BlockedBefore48h() public {
        _supply(lender, 50_000e6);

        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        vm.prank(mod);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);

        bytes32 authHash = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x01),
                _domainSeparator(),
                keccak256(abi.encode(
                    LEVERAGE_AUTH_TYPEHASH,
                    auth.borrower, auth.allowedFrom, auth.recipient, auth.tokenId,
                    auth.maxBorrow, auth.nonce, auth.deadline
                ))
            )
        );

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectRevert(PredmartPoolExtension.TooEarly.selector);
        poolAdmin.expireAdvance(authHash);
    }

    function test_ExpireAdvance_AdminInstant() public {
        _supply(lender, 50_000e6);

        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        vm.prank(mod);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);

        bytes32 authHash = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x01),
                _domainSeparator(),
                keccak256(abi.encode(
                    LEVERAGE_AUTH_TYPEHASH,
                    auth.borrower, auth.allowedFrom, auth.recipient, auth.tokenId,
                    auth.maxBorrow, auth.nonce, auth.deadline
                ))
            )
        );

        // Admin can expire instantly (no 48h wait)
        vm.prank(admin);
        poolAdmin.expireAdvance(authHash);
        assertEq(poolAdmin.pendingAdvances(authHash), 0, "advance cleared by admin");
    }

    function test_ExpireAdvance_PermissionlessAfter48h() public {
        _supply(lender, 50_000e6);

        address mod = makeAddr("module");
        vm.prank(admin);
        poolAdmin.setLeverageModule(mod);

        PredmartBorrowExtension.LeverageAuth memory auth = PredmartBorrowExtension
            .LeverageAuth({
                borrower: borrower,
                allowedFrom: safe,
                recipient: borrower,
                tokenId: TOKEN_ID_YES,
                maxBorrow: 5_000e6,
                nonce: pool.leverageNonces(borrower),
                deadline: block.timestamp + 300
            });

        vm.prank(mod);
        poolBorrow.pullUsdcForLeverage(auth, 0, 1_000e6);

        bytes32 authHash = keccak256(
            abi.encodePacked(
                bytes1(0x19), bytes1(0x01),
                _domainSeparator(),
                keccak256(abi.encode(
                    LEVERAGE_AUTH_TYPEHASH,
                    auth.borrower, auth.allowedFrom, auth.recipient, auth.tokenId,
                    auth.maxBorrow, auth.nonce, auth.deadline
                ))
            )
        );

        // Warp past the 48h gate
        vm.warp(block.timestamp + 48 hours + 1);

        // Random caller can now expire
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        poolAdmin.expireAdvance(authHash);
        assertEq(poolAdmin.pendingAdvances(authHash), 0, "advance cleared after 48h by random caller");
    }
}

/// @notice Mock Gnosis Safe implementing EIP-1271 `isValidSignature`.
///         Returns the magic value (0x1626ba7e) when the signature recovers to the registered owner.
///         Inherits ERC1155Holder so it can hold CTF shares for deposit tests.
contract MockSafe1271 is ERC1155Holder {
    address public owner;
    bytes4 constant MAGIC_VALUE = 0x1626ba7e;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(
        bytes32 hash,
        bytes calldata sig
    ) external view returns (bytes4) {
        if (ECDSA.recover(hash, sig) == owner) return MAGIC_VALUE;
        return 0xffffffff;
    }
}

/// @notice Mock contract that always returns a non-magic value — simulates a malicious or broken EIP-1271 signer.
contract MockSafe1271WrongMagic is ERC1155Holder {
    function isValidSignature(
        bytes32,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xdeadbeef; // Not the expected magic value
    }
}

/// @notice Mock contract whose isValidSignature reverts — verifies SignatureChecker handles reverts gracefully.
contract MockSafe1271Reverts is ERC1155Holder {
    function isValidSignature(
        bytes32,
        bytes calldata
    ) external pure returns (bytes4) {
        revert("isValidSignature reverted");
    }
}
