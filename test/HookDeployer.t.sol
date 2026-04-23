// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookDeployer} from "../src/HookDeployer.sol";
import {FundraisingTokenHook} from "../src/FundraisingTokenHook.sol";

contract MockHookEndpoint {}

contract MockHookIntegrationRegistry {
    address public router;
    address public quoter;
    address public stateView;
    address public poolManager;

    constructor(address _router, address _quoter, address _stateView, address _poolManager) {
        router = _router;
        quoter = _quoter;
        stateView = _stateView;
        poolManager = _poolManager;
    }
}

contract HookDeployerTest is Test {
    address internal factory = address(0xFACA);
    MockHookIntegrationRegistry internal registry;
    HookDeployer internal deployer;
    address internal usdc = address(0x1111);

    function setUp() public {
        registry = new MockHookIntegrationRegistry(
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint())
        );
        deployer = new HookDeployer(factory, usdc, address(registry));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        new HookDeployer(address(0), usdc, address(registry));

        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        new HookDeployer(factory, address(0), address(registry));

        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        new HookDeployer(factory, usdc, address(0));
    }

    function testDeployHookOnlyFactoryAllowed() public {
        vm.expectRevert(HookDeployer.onlyRegistryAllowed.selector);
        deployer.deployHook(bytes32("salt"));
    }

    function testDeployHookUsesRegistryEndpoints() public {
        bytes32 salt = deployer.findSalt();

        vm.prank(address(registry));
        address hookAddress = deployer.deployHook(salt);

        FundraisingTokenHook hook = FundraisingTokenHook(hookAddress);
        assertEq(hook.factoryAddress(), factory);
        assertEq(hook.usdcAddress(), usdc);
        assertEq(hook.router(), registry.router());
        assertEq(hook.quoter(), registry.quoter());
        assertEq(hook.stateView(), registry.stateView());
    }

    function testFindSaltReturnsNonZeroSalt() public view {
        bytes32 salt = deployer.findSalt();
        assertTrue(salt != bytes32(0));
    }
}
