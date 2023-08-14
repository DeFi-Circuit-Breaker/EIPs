// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "../../mocks/MockToken.sol";
import {MockDeFiProtocol} from "../../mocks/MockDeFiProtocol.sol";
import {TokenCircuitBreaker} from "../../../src/core/TokenCircuitBreaker.sol";
import {DelayedSettlementModule} from "../../../src/settlement/DelayedSettlementModule.sol";
import {LimiterLib} from "../../../src/utils/LimiterLib.sol";

contract CircuitBreakerAdminOpsTest is Test {
    MockToken internal token;
    MockToken internal secondToken;
    MockToken internal unlimitedToken;

    address internal NATIVE_ADDRESS_PROXY = address(1);
    TokenCircuitBreaker internal circuitBreaker;
    DelayedSettlementModule internal delayedSettlementModule;
    MockDeFiProtocol internal deFi;

    address internal alice = vm.addr(0x1);
    address internal bob = vm.addr(0x2);
    address internal admin = vm.addr(0x3);

    function setUp() public {
        token = new MockToken("USDC", "USDC");
        circuitBreaker = new TokenCircuitBreaker(4 hours, 5 minutes);
        circuitBreaker.transferOwnership(admin);
        deFi = new MockDeFiProtocol(address(circuitBreaker));

        address[] memory addresses = new address[](1);
        addresses[0] = address(deFi);

        vm.prank(admin);
        circuitBreaker.addProtectedContracts(addresses);

        vm.prank(admin);
        // Protect USDC with 70% max drawdown per 4 hours
        circuitBreaker.registerAsset(address(token), 7000, 1000e18, address(delayedSettlementModule));
        vm.prank(admin);
        circuitBreaker.registerAsset(NATIVE_ADDRESS_PROXY, 7000, 1000e18, address(delayedSettlementModule));
        vm.warp(1 hours);
    }

    function test_initialization_shouldBeSuccessful() public {
        TokenCircuitBreaker newCircuitBreaker = new TokenCircuitBreaker(3 hours, 5 minutes);
        newCircuitBreaker.transferOwnership(admin);
        assertEq(newCircuitBreaker.owner(), admin);
    }

    function test_registerAsset_whenMinimumLiquidityThresholdIsInvalidShouldFail() public {
        secondToken = new MockToken("DAI", "DAI");
        vm.prank(admin);
        vm.expectRevert(LimiterLib.InvalidMinimumLiquidityThreshold.selector);
        circuitBreaker.registerAsset(address(secondToken), 0, 1000e18, address(delayedSettlementModule));

        vm.prank(admin);
        vm.expectRevert(LimiterLib.InvalidMinimumLiquidityThreshold.selector);
        circuitBreaker.registerAsset(address(secondToken), 10_001, 1000e18, address(delayedSettlementModule));

        vm.prank(admin);
        vm.expectRevert(LimiterLib.InvalidMinimumLiquidityThreshold.selector);
        circuitBreaker.updateAssetParams(address(secondToken), 0, 2000e18, address(delayedSettlementModule));

        vm.prank(admin);
        vm.expectRevert(LimiterLib.InvalidMinimumLiquidityThreshold.selector);
        circuitBreaker.updateAssetParams(address(secondToken), 10_001, 2000e18, address(delayedSettlementModule));
    }

    function test_registerAsset_whenAlreadyRegisteredShouldFail() public {
        secondToken = new MockToken("DAI", "DAI");
        vm.prank(admin);
        circuitBreaker.registerAsset(address(secondToken), 7000, 1000e18, address(delayedSettlementModule));
        // Cannot register the same token twice
        vm.expectRevert(LimiterLib.LimiterAlreadyInitialized.selector);
        vm.prank(admin);
        circuitBreaker.registerAsset(address(secondToken), 7000, 1000e18, address(delayedSettlementModule));
    }

    function test_registerAsset_shouldBeSuccessful() public {
        secondToken = new MockToken("DAI", "DAI");
        bytes32 identifier = keccak256(abi.encodePacked(address(secondToken)));

        vm.prank(admin);
        circuitBreaker.registerAsset(address(secondToken), 7000, 1000e18, address(delayedSettlementModule));
        (uint256 minLiquidityThreshold, uint256 minAmount,,,,,) = circuitBreaker.limiters(identifier);
        assertEq(minAmount, 1000e18);
        assertEq(minLiquidityThreshold, 7000);

        vm.prank(admin);
        circuitBreaker.updateAssetParams(address(secondToken), 8000, 2000e18, address(delayedSettlementModule));
        (minLiquidityThreshold, minAmount,,,,,) = circuitBreaker.limiters(identifier);
        assertEq(minAmount, 2000e18);
        assertEq(minLiquidityThreshold, 8000);
    }

    function test_addProtectedContracts_shouldBeSuccessful() public {
        MockDeFiProtocol secondDeFi = new MockDeFiProtocol(address(circuitBreaker));

        address[] memory addresses = new address[](1);
        addresses[0] = address(secondDeFi);
        vm.prank(admin);
        circuitBreaker.addProtectedContracts(addresses);

        assertEq(circuitBreaker.isProtectedContract(address(secondDeFi)), true);
    }

    function test_removeProtectedContracts_shouldBeSuccessful() public {
        MockDeFiProtocol secondDeFi = new MockDeFiProtocol(address(circuitBreaker));

        address[] memory addresses = new address[](1);
        addresses[0] = address(secondDeFi);
        vm.prank(admin);
        circuitBreaker.addProtectedContracts(addresses);

        vm.prank(admin);
        circuitBreaker.removeProtectedContracts(addresses);
        assertEq(circuitBreaker.isProtectedContract(address(secondDeFi)), false);
    }
}
