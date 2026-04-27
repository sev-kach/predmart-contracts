// test/PredmartLeverageModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PredmartLeverageModule, ISafe} from "../src/PredmartLeverageModule.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Mock Safe that holds USDC balance and forwards execTransactionFromModule
///         calls (operation=CALL) by performing the encoded call as itself.
///         For test simplicity only handles transfer() — that's all executeLeverage does.
contract MockSafe {
    mapping(address => bool) public owners;
    bool public shouldExecSucceed = true;
    address public usdc;

    function addOwner(address o) external { owners[o] = true; }
    function setShouldExecSucceed(bool ok) external { shouldExecSucceed = ok; }
    function setUSDC(address u) external { usdc = u; }
    function isOwner(address o) external view returns (bool) { return owners[o]; }

    function execTransactionFromModule(address to, uint256 /*value*/, bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        if (!shouldExecSucceed) return false;
        require(operation == 0, "expected call");
        require(to == usdc, "wrong target");
        // Decode IERC20.transfer(to, amount) and execute it as the Safe.
        (address recipient, uint256 amount) = abi.decode(data[4:], (address, uint256));
        MockUSDC(usdc).transfer(recipient, amount);
        return true;
    }
}

/// @notice Mock pool that captures the args of pullUsdcForLeverage for assertion.
///         Mirrors the storage layout the module expects (relayer + leverageModule).
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
    MockUSDC usdc;

    address relayer = address(0xCAFE);
    uint256 borrowerPk = 0xBEEF;
    address borrower;

    PredmartLeverageModule.LeverageAuth auth;

    function setUp() public {
        usdc = new MockUSDC();
        pool = new MockPool();
        module = new PredmartLeverageModule(address(pool), relayer, address(usdc));
        safe = new MockSafe();
        safe.setUSDC(address(usdc));

        borrower = vm.addr(borrowerPk);
        safe.addOwner(borrower);

        // Fund the Safe with USDC so the module's transfer can succeed.
        usdc.mint(address(safe), 10_000_000); // $10

        auth = PredmartLeverageModule.LeverageAuth({
            borrower: borrower,
            allowedFrom: address(safe),
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

    function test_executeLeverage_pulls_userAmount_and_calls_pool() public {
        (bytes memory sig,) = _signAuth(borrowerPk);

        uint256 userAmount = 1_000_000; // $1
        uint256 advanceAmount = 2_000_000; // $2 — pool will record but doesn't transfer in mock

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        uint256 relayerBalBefore = usdc.balanceOf(relayer);

        module.executeLeverage(ISafe(address(safe)), auth, sig, userAmount, advanceAmount);

        // Safe → relayer: userAmount in USDC moved this tx
        assertEq(usdc.balanceOf(address(safe)), safeBalBefore - userAmount, "safe USDC decreased");
        assertEq(usdc.balanceOf(relayer), relayerBalBefore + userAmount, "relayer USDC increased");

        // Pool received the right call args
        assertEq(pool.callCount(), 1, "pool called once");
        assertEq(pool.lastUserAmount(), userAmount, "pool got userAmount");
        assertEq(pool.lastAdvanceAmount(), advanceAmount, "pool got advanceAmount");
    }

    function test_executeLeverage_zero_userAmount_skips_safe_transfer() public {
        (bytes memory sig,) = _signAuth(borrowerPk);

        uint256 safeBalBefore = usdc.balanceOf(address(safe));
        uint256 relayerBalBefore = usdc.balanceOf(relayer);

        // userAmount = 0, advanceAmount > 0 — module shouldn't touch the Safe
        module.executeLeverage(ISafe(address(safe)), auth, sig, 0, 1_000_000);

        assertEq(usdc.balanceOf(address(safe)), safeBalBefore, "safe USDC unchanged");
        assertEq(usdc.balanceOf(relayer), relayerBalBefore, "relayer USDC unchanged");
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
        vm.expectRevert(PredmartLeverageModule.SafeUsdcPullFailed.selector);
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

    function test_immutables_set_correctly() public {
        assertEq(module.LENDING_POOL(), address(pool));
        assertEq(module.RELAYER(), relayer);
        assertEq(module.USDC(), address(usdc));
        assertEq(module.VERSION(), "1.0.0");
    }
}
