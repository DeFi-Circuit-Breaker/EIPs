// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {DelayedSettlementModule} from "../../src/settlement/DelayedSettlementModule.sol";

contract DelayedSettlementModuleTest is Test {
    MockToken internal token;
    DelayedSettlementModule internal delayedSettlementModule;

    address internal alice = vm.addr(0x1);
    address internal bob = vm.addr(0x2);
    address internal admin = vm.addr(0x3);

    function setUp() public {
        token = new MockToken("USDC", "USDC");
        address[] memory admins = new address[](1);
        admins[0] = admin;

        delayedSettlementModule = new DelayedSettlementModule(
            1 seconds,
            admins, // proposer = admin
            admins, // executor = admin
            admin
        );
    }

    function test_prevent() public {
        bytes memory innerPayload = abi.encodeWithSignature(
            "transfer(address,uint256)",
            bob,
            1_000e18
        );

        vm.prank(admin);
        bytes32 effectID = delayedSettlementModule.prevent(
            address(token),
            0,
            innerPayload
        );
        assertEq(
            effectID,
            keccak256(abi.encode(address(token), 0, innerPayload)),
            "Effect ID mismatch."
        );
    }

    function test_execute() public {
        bytes memory innerPayload = abi.encodeWithSignature(
            "mint(address,uint256)",
            bob,
            1_000e18
        );

        vm.prank(admin);
        bytes32 effectID = delayedSettlementModule.prevent(
            address(token),
            0,
            innerPayload
        );

        // warp time to exceed the minimum delay
        vm.warp(2 seconds);

        vm.prank(admin);
        delayedSettlementModule.execute(address(token), 0, innerPayload);

        // Assert that Bob now has the minted tokens
        assertEq(token.balanceOf(bob), 1_000e18, "Bob didn't receive tokens.");
    }
}
