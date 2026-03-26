// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookDeployer} from "../src/HookDeployer.sol";
import {FundraisingTokenHook} from "../src/FundraisingTokenHook.sol";
import {IFactory} from "../src/interfaces/IFactory.sol";

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

contract MockHookFactory {
    IFactory.FundraisingProtocol internal protocol;

    function setProtocol(IFactory.FundraisingProtocol memory newProtocol) external {
        protocol = newProtocol;
    }

    function getProtocol(address) external view returns (IFactory.FundraisingProtocol memory) {
        return protocol;
    }
}

contract HookDeployerTest is Test {
    MockHookFactory internal factory;
    MockHookIntegrationRegistry internal registry;
    HookDeployer internal deployer;

    address internal fundraisingToken = address(0x1111);
    address internal vault = address(0x2222);

    function setUp() public {
        factory = new MockHookFactory();
        registry = new MockHookIntegrationRegistry(
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint()),
            address(new MockHookEndpoint())
        );
        deployer = new HookDeployer(address(factory), address(registry));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        new HookDeployer(address(0), address(registry));

        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        new HookDeployer(address(factory), address(0));
    }

    function testDeployHookOnlyFactoryAllowed() public {
        vm.expectRevert(HookDeployer.onlyFactoryAllowed.selector);
        deployer.deployHook(fundraisingToken, vault, bytes32("salt"));
    }

    function testDeployHookUsesRegistryEndpoints() public {
        factory.setProtocol(
            IFactory.FundraisingProtocol({
                fundraisingToken: fundraisingToken,
                underlyingAddress: address(0x3333),
                vault: vault,
                hook: address(0),
                isLPCreated: false
            })
        );
        bytes32 salt = deployer.findSalt(address(0xBEEF));

        vm.prank(address(factory));
        address hookAddress = deployer.deployHook(fundraisingToken, vault, salt);

        FundraisingTokenHook hook = FundraisingTokenHook(hookAddress);
        assertEq(hook.fundraisingTokenAddress(), fundraisingToken);
        assertEq(hook.vault(), vault);
        assertEq(hook.router(), registry.router());
        assertEq(hook.quoter(), registry.quoter());
        assertEq(hook.stateView(), registry.stateView());
    }

    function testFindSaltRejectsZeroOwner() public {
        vm.expectRevert(HookDeployer.ZeroAddress.selector);
        deployer.findSalt(address(0));
    }

    function testFindSaltRequiresProtocol() public {
        vm.expectRevert(HookDeployer.ProtocolNotAvailable.selector);
        deployer.findSalt(address(0xBEEF));
    }

    function testFindSaltReturnsNonZeroSaltForConfiguredProtocol() public {
        factory.setProtocol(
            IFactory.FundraisingProtocol({
                fundraisingToken: fundraisingToken,
                underlyingAddress: address(0x3333),
                vault: vault,
                hook: address(0),
                isLPCreated: false
            })
        );

        bytes32 salt = deployer.findSalt(address(0xBEEF));

        assertTrue(salt != bytes32(0));
    }
}
