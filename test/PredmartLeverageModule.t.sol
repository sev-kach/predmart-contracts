// test/PredmartLeverageModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PredmartLeverageModule, ISafe} from "../src/PredmartLeverageModule.sol";

/// @notice Mock Safe — minimal surface so we can drive execTransactionFromModule and
///         observe the SignMessageLib delegatecall.
contract MockSafe {
    mapping(address => bool) public owners;
    bytes32 public lastDelegateTo;
    bytes public lastDelegateData;
    bool public shouldExecSucceed = true;

    // SignMessageLib's signMessage writes to slot 7 (signedMessages mapping).
    // We mimic the storage layout for the test by exposing the slot directly.
    mapping(bytes32 => uint256) public signedMessages;

    address public signMessageLibImpl;

    function addOwner(address o) external {
        owners[o] = true;
    }

    function setSignMessageLib(address impl) external {
        signMessageLibImpl = impl;
    }

    function setShouldExecSucceed(bool ok) external {
        shouldExecSucceed = ok;
    }

    function isOwner(address o) external view returns (bool) {
        return owners[o];
    }

    function execTransactionFromModule(address to, uint256, /* value */ bytes calldata data, uint8 operation)
        external
        returns (bool)
    {
        if (!shouldExecSucceed) return false;
        require(operation == 1, "expected delegatecall");
        require(to == signMessageLibImpl, "wrong delegate target");
        lastDelegateTo = bytes32(uint256(uint160(to)));
        lastDelegateData = data;

        // Decode signMessage(bytes _data) → _data is abi.encode(authHash) → authHash bytes32
        bytes memory inner;
        // skip 4-byte selector + 32-byte offset + 32-byte length, then read 32 bytes
        bytes32 selector;
        assembly {
            selector := calldataload(data.offset)
        }
        // strip selector and outer abi.encode wrapping
        bytes calldata payload = data[4:];
        bytes memory unwrapped = abi.decode(payload, (bytes));
        bytes32 authHash;
        assembly {
            authHash := mload(add(unwrapped, 32))
        }
        // Match Safe's wrapping: messageHash = keccak256(\x19\x01 || safeDomainSep || keccak256(SafeMessage typehash + dataHash))
        // For test purposes, we record under authHash directly — the module already
        // computed the right shape upstream; what matters is signMessage was invoked.
        signedMessages[authHash] = 1;
        return true;
    }

    // Simulate SignMessageLib's signMessage being delegatecalled — but the MockSafe
    // does the storage write itself in execTransactionFromModule above for test simplicity.
}

/// @notice Mock SignMessageLib — present so the module's delegate target check has a real
///         address. Storage writes happen in MockSafe (via the mock's own assembly path).
contract MockSignMessageLib {
    function signMessage(bytes calldata) external pure {}
}

contract PredmartLeverageModuleTest is Test {
    PredmartLeverageModule module;
    MockSafe safe;
    MockSignMessageLib signLib;

    address pool = address(0xCAFE);
    uint256 borrowerPk = 0xBEEF;
    address borrower;

    PredmartLeverageModule.LeverageAuth auth;

    function setUp() public {
        signLib = new MockSignMessageLib();
        module = new PredmartLeverageModule(pool, address(signLib));
        safe = new MockSafe();
        safe.setSignMessageLib(address(signLib));

        borrower = vm.addr(borrowerPk);
        safe.addOwner(borrower);

        auth = PredmartLeverageModule.LeverageAuth({
            borrower: borrower,
            allowedFrom: address(safe),
            tokenId: 12345,
            maxBorrow: 1_000_000,
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

    function test_preapprove_succeeds_with_valid_owner_signature() public {
        (bytes memory sig, bytes32 authHash) = _signAuth(borrowerPk);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
        assertEq(safe.signedMessages(authHash), 1, "auth hash should be marked approved");
    }

    function test_preapprove_reverts_when_safe_address_mismatch() public {
        auth.allowedFrom = address(0xDEAD);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.WrongSafe.selector);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }

    function test_preapprove_reverts_with_invalid_signature() public {
        (bytes memory sig,) = _signAuth(0xBAD);
        vm.expectRevert(PredmartLeverageModule.InvalidBorrowerSignature.selector);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }

    function test_preapprove_reverts_when_borrower_not_owner() public {
        // borrower signs validly but is not an owner of the Safe
        uint256 nonOwnerPk = 0xC0DE;
        address nonOwner = vm.addr(nonOwnerPk);
        auth.borrower = nonOwner;
        (bytes memory sig,) = _signAuth(nonOwnerPk);
        vm.expectRevert(PredmartLeverageModule.BorrowerNotSafeOwner.selector);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }

    function test_preapprove_reverts_when_safe_exec_fails() public {
        safe.setShouldExecSucceed(false);
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.expectRevert(PredmartLeverageModule.SignMessageFailed.selector);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }

    function test_preapprove_is_permissionless() public {
        // anyone may submit the relayer-signed auth — caller identity is not checked
        (bytes memory sig,) = _signAuth(borrowerPk);
        vm.prank(address(0x1234));
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }

    function test_preapprove_emits_event() public {
        (bytes memory sig, bytes32 authHash) = _signAuth(borrowerPk);
        vm.expectEmit(true, true, true, true);
        emit PredmartLeverageModule.AuthPreapproved(address(safe), authHash, borrower);
        module.preapproveAuth(ISafe(address(safe)), auth, sig);
    }
}
