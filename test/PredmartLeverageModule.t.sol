// test/PredmartLeverageModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PredmartLeverageModule, ISafe} from "../src/PredmartLeverageModule.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Mock pUSD — same interface as MockUSDC, separate contract so balances don't co-mingle.
contract MockPUSD is MockUSDC {}

/// @notice Mock CollateralOnramp — wraps USDC.e from caller into pUSD minted to recipient.
contract MockCollateralOnramp {
    address public usdcE;
    address public pusd;
    bool public shouldFail;

    function setTokens(address _usdcE, address _pusd) external { usdcE = _usdcE; pusd = _pusd; }
    function setShouldFail(bool v) external { shouldFail = v; }

    function wrap(address _asset, address _to, uint256 _amount) external {
        require(!shouldFail, "wrap failed");
        require(_asset == usdcE, "wrong asset");
        MockUSDC(usdcE).transferFrom(msg.sender, address(this), _amount);
        MockPUSD(pusd).mint(_to, _amount);
    }
}

/// @notice Mock Safe that holds token balances and forwards execTransactionFromModule calls.
///         Approves the onramp on USDC.e during setup to allow wrap. Executes the encoded
///         transfer / wrap as itself.
contract MockSafe {
    mapping(address => bool) public owners;
    bool public shouldExecSucceed = true;
    address public pusd;
    address public usdcE;
    address public onramp;

    function addOwner(address o) external { owners[o] = true; }
    function setShouldExecSucceed(bool ok) external { shouldExecSucceed = ok; }
    function setTokens(address _pusd, address _usdcE, address _onramp) external {
        pusd = _pusd;
        usdcE = _usdcE;
        onramp = _onramp;
        // Approve onramp to pull USDC.e during wrap.
        MockUSDC(_usdcE).approve(_onramp, type(uint256).max);
    }
    function isOwner(address o) external view returns (bool) { return owners[o]; }

    function execTransactionFromModule(address to, uint256 /*value*/, bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        if (!shouldExecSucceed) return false;
        require(operation == 0, "expected call");
        // Re-execute the call from this contract's context.
        (bool ok, ) = to.call(data);
        return ok;
    }
}

/// @notice Mock pool that captures pullUsdcForLeverage args and mirrors the storage
///         layout the module expects. Runs as standalone contract — module calls it directly.
contract MockPool {
    PredmartLeverageModule.LeverageAuth public lastAuth;
    uint256 public lastUserAmount;
    uint256 public lastAdvanceAmount;
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(bool v) external { shouldRevert = v; }

    function pullUsdcForLeverage(
        PredmartLeverageModule.LeverageAuth calldata auth,
        uint256 userAmount,
        uint256 advanceAmount
    ) external {
        if (shouldRevert) revert("pool revert");
        lastAuth = auth;
        lastUserAmount = userAmount;
        lastAdvanceAmount = advanceAmount;
        callCount += 1;
    }
}

contract PredmartLeverageModuleTest is Test {
    PredmartLeverageModule module;
    MockSafe safe;
    MockPool pool;
    MockUSDC usdcE;
    MockPUSD pusd;
    MockCollateralOnramp onramp;

    address relayer = address(0xCAFE);
    uint256 borrowerPk = 0xBEEF;
    address borrower;

    PredmartLeverageModule.LeverageAuth auth;

    function setUp() public {
        usdcE = new MockUSDC();
        pusd = new MockPUSD();
        onramp = new MockCollateralOnramp();
        onramp.setTokens(address(usdcE), address(pusd));

        pool = new MockPool();
        module = new PredmartLeverageModule(
            address(pool),
            relayer,
            address(usdcE),
            address(pusd),
            address(onramp)
        );

        safe = new MockSafe();
        safe.setTokens(address(pusd), address(usdcE), address(onramp));

        borrower = vm.addr(borrowerPk);
        safe.addOwner(borrower);

        // Fund the Safe with pUSD by default — happy path needs no wrap.
        pusd.mint(address(safe), 10_000_000); // $10

        auth = PredmartLeverageModule.LeverageAuth({
            borrower: borrower,
            allowedFrom: address(safe),
            recipient: borrower,
            tokenId: 12345,
            maxBorrow: 5_000_000, // $5
            nonce: 0,
            deadline: type(uint256).max
        });
    }

    function _signAuth(uint256 pk) internal view returns (bytes memory, bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                module.LEVERAGE_AUTH_TYPEHASH(),
                auth.borrower,
                auth.allowedFrom,
                auth.recipient,
                auth.tokenId,
                auth.maxBorrow,
                auth.nonce,
                auth.deadline
            )
        );
        bytes32 authHash = keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), module.POOL_DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, authHash);
        return (abi.encodePacked(r, s, v), authHash);
    }

    /*//////////////////////////////////////////////////////////////
                          HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_executeLeverage_pulls_pusd_and_calls_pool() public {
        (bytes memory sig,) = _signAuth(borrowerPk);

        uint256 userAmount = 1_000_000; // $1
        uint256 advanceAmount = 2_000_000; // $2

        uint256 safeBalBefore = pusd.balanceOf(address(safe));
        uint256 relayerBalBefore = pusd.balanceOf(relayer);

        module.executeLeverage(ISafe(address(safe)), auth, sig, userAmount, advanceAmount);

        // Safe → relayer: userAmount in pUSD moved this tx
        assertEq(pusd.balanceOf(address(safe)), safeBalBefore - userAmount, "safe pUSD decreased");
        assertEq(pusd.balanceOf(relayer), relayerBalBefore + userAmount, "relayer pUSD increased");

        // Pool received the right call args
        assertEq(pool.callCount(), 1, "pool called once");
        assertEq(pool.lastUserAmount(), userAmount, "pool got userAmount");
        assertEq(pool.lastAdvanceAmount(), advanceAmount, "pool got advanceAmount");
    }

    function test_executeLeverage_wraps_usdce_when_pusd_short() public {
        // Safe has 0 pUSD, $10 USDC.e — module should wrap-all then pull.
        deal(address(pusd), address(safe), 0);
        usdcE.mint(address(safe), 10_000_000);

        (bytes memory sig,) = _signAuth(borrowerPk);
        uint256 userAmount = 1_000_000;

        module.executeLeverage(ISafe(address(safe)), auth, sig, userAmount, 0);

        // After wrap-all: safe USDC.e zeroed, pUSD = (10 - 1) = 9
        assertEq(usdcE.balanceOf(address(safe)), 0, "USDC.e wrapped");
        assertEq(pusd.balanceOf(address(safe)), 10_000_000 - userAmount, "pUSD remaining after pull");
        assertEq(pusd.balanceOf(relayer), userAmount, "relayer got pUSD");
    }

    function test_executeLeverage_zero_userAmount_skips_safe_transfer() public {
        (bytes memory sig,) = _signAuth(borrowerPk);

        uint256 safeBalBefore = pusd.balanceOf(address(safe));
        uint256 relayerBalBefore = pusd.balanceOf(relayer);

        module.executeLeverage(ISafe(address(safe)), auth, sig, 0, 1_000_000);

        assertEq(pusd.balanceOf(address(safe)), safeBalBefore, "safe pUSD unchanged");
        assertEq(pusd.balanceOf(relayer), relayerBalBefore, "relayer pUSD unchanged");
        assertEq(pool.callCount(), 1, "pool still called");
        assertEq(pool.lastUserAmount(), 0);
        assertEq(pool.lastAdvanceAmount(), 1_000_000);
    }

    function test_executeLeverage_emits_event() public {
        (bytes memory sig,) = _signAuth(borrowerPk);

        vm.expectEmit(true, true, true, true);
        emit PredmartLeverageModule.LeverageExecuted(
            address(safe), borrower, auth.tokenId, 1_000_000, 2_000_000
        );
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 2_000_000);
    }

    function test_executeLeverage_is_permissionless() public {
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.prank(address(0xDEADBEEF));
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 2_000_000);
        assertEq(pool.callCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          REVERT PATHS
    //////////////////////////////////////////////////////////////*/

    function test_executeLeverage_reverts_when_safe_address_mismatch() public {
        auth.allowedFrom = address(0xDEAD);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.WrongSafe.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_reverts_with_invalid_signature() public {
        (bytes memory sig,) = _signAuth(0xBAD);
        vm.expectRevert(PredmartLeverageModule.InvalidBorrowerSignature.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_reverts_when_borrower_not_owner() public {
        uint256 nonOwnerPk = 0xC0DE;
        address nonOwner = vm.addr(nonOwnerPk);
        auth.borrower = nonOwner;
        (bytes memory sig,) = _signAuth(nonOwnerPk);
        vm.expectRevert(PredmartLeverageModule.BorrowerNotSafeOwner.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_reverts_when_safe_exec_fails() public {
        safe.setShouldExecSucceed(false);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.SafePullFailed.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_reverts_when_funds_insufficient() public {
        // No pUSD, no USDC.e — wrap can't cover pull.
        deal(address(pusd), address(safe), 0);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.InsufficientSafeFunds.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_reverts_on_zero_recipient() public {
        auth.recipient = address(0);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.InvalidRecipient.selector);
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 0);
    }

    function test_executeLeverage_propagates_pool_revert() public {
        pool.setShouldRevert(true);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(); // bubbles up "pool revert"
        module.executeLeverage(ISafe(address(safe)), auth, sig, 1_000_000, 2_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES & VERSION
    //////////////////////////////////////////////////////////////*/

    function test_immutables_set_correctly() public view {
        assertEq(module.LENDING_POOL(), address(pool));
        assertEq(module.RELAYER(), relayer);
        assertEq(module.USDC_E(), address(usdcE));
        assertEq(module.PUSD(), address(pusd));
        assertEq(module.COLLATERAL_ONRAMP(), address(onramp));
        assertEq(module.VERSION(), "2.0.0");
    }
}
