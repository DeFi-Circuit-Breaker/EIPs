// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {MockToken} from "../../mocks/MockToken.sol";
import {MockDeFiProtocol} from "../../mocks/MockDeFiProtocol.sol";

import "../../../src/core/CircuitBreaker.sol";
import {AssetCircuitBreaker} from "../../../src/core/AssetCircuitBreaker.sol";
import {DelayedSettlementModule} from "../../../src/settlement/DelayedSettlementModule.sol";
import {LimiterLib} from "../../../src/utils/LimiterLib.sol";

contract CircuitBreakerEmergencyOpsTest is Test {
    event FundsReleased(address indexed token);
    event HackerFundsWithdrawn(
        address indexed hacker,
        address indexed token,
        address indexed receiver,
        uint256 amount
    );

    MockToken internal token;
    MockToken internal secondToken;
    MockToken internal unlimitedToken;

    address internal NATIVE_ADDRESS_PROXY = address(1);
    AssetCircuitBreaker internal circuitBreaker;
    DelayedSettlementModule internal delayedSettlementModule;
    MockDeFiProtocol internal deFi;

    address internal alice = vm.addr(0x1);
    address internal bob = vm.addr(0x2);
    address internal admin = vm.addr(0x3);

    function setUp() public {
        circuitBreaker = new AssetCircuitBreaker(3 days, 4 hours, 5 minutes, admin);
        delayedSettlementModule = new DelayedSettlementModule(
            1 seconds,
            new address[](0),
            new address[](0),
            admin
        );

        // allow token circuit breaker to propose (for calling prevent function)
        vm.prank(admin);
        delayedSettlementModule.grantRole(
            keccak256("PROPOSER_ROLE"),
            address(circuitBreaker)
        );

        token = new MockToken("USDC", "USDC");
        deFi = new MockDeFiProtocol(address(circuitBreaker));

        address[] memory addresses = new address[](1);
        addresses[0] = address(deFi);

        vm.prank(admin);
        circuitBreaker.addProtectedContracts(addresses);

        vm.prank(admin);
        // Protect USDC with 70% max drawdown per 4 hours
        circuitBreaker.registerAsset(
            address(token),
            7000,
            1000e18,
            address(delayedSettlementModule)
        );
        vm.prank(admin);
        circuitBreaker.registerAsset(
            NATIVE_ADDRESS_PROXY,
            7000,
            1000e18,
            address(delayedSettlementModule)
        );
        vm.warp(1 hours);
    }

    function test_ifTokenNotRateLimitedShouldFail() public {
        secondToken = new MockToken("DAI", "DAI");
        vm.prank(admin);
        circuitBreaker.registerAsset(
            address(secondToken),
            7000,
            1000e18,
            address(delayedSettlementModule)
        );

        token.mint(alice, 1_000_000e18);

        vm.prank(alice);
        token.approve(address(deFi), 1_000_000e18);

        vm.prank(alice);
        deFi.deposit(address(token), 1_000_000e18);

        int256 withdrawalAmount = 300_001e18;
        vm.warp(5 hours);
        vm.prank(alice);
        deFi.withdrawal(address(token), uint256(withdrawalAmount));
        assertEq(circuitBreaker.isRateLimited(), true);
        assertEq(
            circuitBreaker.isTokenRateLimited(address(secondToken)),
            false
        );
    }

    function test_reverts_ifIsNotOperational() public {
        token.mint(alice, 1_000_000e18);

        vm.prank(alice);
        token.approve(address(deFi), 1_000_000e18);

        vm.prank(alice);
        deFi.deposit(address(token), 1_000_000e18);

        int256 withdrawalAmount = 300_001e18;
        vm.warp(5 hours);
        vm.prank(alice);
        deFi.withdrawal(address(token), uint256(withdrawalAmount));

        assertEq(circuitBreaker.isTokenRateLimited(address(token)), true);

        // Exploit
        vm.prank(admin);
        circuitBreaker.setCircuitBreakerOperationalStatus(false);

        token.mint(alice, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(deFi), 1_000_000e18);

        vm.expectRevert(CircuitBreaker.CircuitBreaker__NotOperational.selector);
        vm.prank(alice);
        deFi.deposit(address(token), 1_000_000e18);

        vm.expectRevert(CircuitBreaker.CircuitBreaker__NotOperational.selector);
        vm.prank(alice);
        deFi.withdrawal(address(token), uint256(withdrawalAmount));

        vm.deal(alice, 1_000_000e18);
        vm.expectRevert(CircuitBreaker.CircuitBreaker__NotOperational.selector);
        vm.prank(alice);
        deFi.depositNative{value: 1_000_000e18}();
    }
}
