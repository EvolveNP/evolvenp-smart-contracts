// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IntegrationRegistry} from "../src/IntegrationRegistry.sol";

contract MockEmergencyState {
    bool internal active;

    function setActive(bool value) external {
        active = value;
    }

    function isEmergencyActive() external view returns (bool) {
        return active;
    }
}

contract MockEndpoint {}

contract IntegrationRegistryTest is Test {
    MockEmergencyState internal emergencyState;
    MockEndpoint internal router;
    MockEndpoint internal permit2;
    MockEndpoint internal quoter;
    MockEndpoint internal poolManager;
    MockEndpoint internal positionManager;
    MockEndpoint internal stateView;

    IntegrationRegistry internal registry;

    function setUp() public {
        emergencyState = new MockEmergencyState();
        router = new MockEndpoint();
        permit2 = new MockEndpoint();
        quoter = new MockEndpoint();
        poolManager = new MockEndpoint();
        positionManager = new MockEndpoint();
        stateView = new MockEndpoint();

        registry = new IntegrationRegistry(
            address(router),
            address(permit2),
            address(quoter),
            address(poolManager),
            address(positionManager),
            address(stateView),
            address(emergencyState)
        );
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(IntegrationRegistry.ZeroAddress.selector);
        new IntegrationRegistry(
            address(0),
            address(permit2),
            address(quoter),
            address(poolManager),
            address(positionManager),
            address(stateView),
            address(emergencyState)
        );
    }

    function testSetAllowedAddressRejectsAddressesWithoutCode() public {
        vm.expectRevert(IntegrationRegistry.NoCodeAtAddress.selector);
        registry.setAllowedAddress(IntegrationRegistry.Endpoint.ROUTER, address(0x1234), true);
    }

    function testUpdateIntegrationRequiresAllowlistedAddress() public {
        address newRouter = address(new MockEndpoint());

        vm.expectRevert(IntegrationRegistry.NotAllowedAtAddress.selector);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter);
    }

    function testUpdateIntegrationRequiresActiveEmergency() public {
        address newRouter = address(new MockEndpoint());
        registry.setAllowedAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter, true);

        vm.expectRevert(IntegrationRegistry.EmergencyIsNotActive.selector);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter);
    }

    function testUpdateEachEndpointWhenEmergencyIsActive() public {
        emergencyState.setActive(true);

        address newRouter = _allowlistedEndpoint(IntegrationRegistry.Endpoint.ROUTER);
        address newPermit2 = _allowlistedEndpoint(IntegrationRegistry.Endpoint.PERMIT2);
        address newQuoter = _allowlistedEndpoint(IntegrationRegistry.Endpoint.QUOTER);
        address newPoolManager = _allowlistedEndpoint(IntegrationRegistry.Endpoint.POOL_MANAGER);
        address newPositionManager = _allowlistedEndpoint(IntegrationRegistry.Endpoint.POSITION_MANAGER);
        address newStateView = _allowlistedEndpoint(IntegrationRegistry.Endpoint.STATE_VIEW);

        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.PERMIT2, newPermit2);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.QUOTER, newQuoter);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.POOL_MANAGER, newPoolManager);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.POSITION_MANAGER, newPositionManager);
        registry.updateIntegrationAddress(IntegrationRegistry.Endpoint.STATE_VIEW, newStateView);

        assertEq(registry.router(), newRouter);
        assertEq(registry.permit2(), newPermit2);
        assertEq(registry.quoter(), newQuoter);
        assertEq(registry.poolManager(), newPoolManager);
        assertEq(registry.positionManager(), newPositionManager);
        assertEq(registry.stateView(), newStateView);
    }

    function testSetAllowedAddressCanRemoveAddress() public {
        address newRouter = _allowlistedEndpoint(IntegrationRegistry.Endpoint.ROUTER);
        assertTrue(registry.isAllowedAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter));

        registry.setAllowedAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter, false);

        assertFalse(registry.isAllowedAddress(IntegrationRegistry.Endpoint.ROUTER, newRouter));
    }

    function _allowlistedEndpoint(IntegrationRegistry.Endpoint endpoint) internal returns (address endpointAddress) {
        endpointAddress = address(new MockEndpoint());
        registry.setAllowedAddress(endpoint, endpointAddress, true);
    }
}
