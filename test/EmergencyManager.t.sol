// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {EmergencyManager} from "../src/EmergencyManager.sol";
import {IEmergencyManager} from "../src/interfaces/IEmergencyManager.sol";

contract EmergencyManagerTest is Test {
    address internal multisig = address(0xA11CE);
    address internal reporterRegistrar = address(0xFACADE);
    address internal reporter = address(0xB0B);

    EmergencyManager internal manager;

    function setUp() public {
        address[] memory reporters = new address[](1);
        reporters[0] = reporter;

        EmergencyManager.Config memory config = EmergencyManager.Config({
            emergencyDuration: 3 days,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3
        });

        manager = new EmergencyManager(multisig, reporterRegistrar, reporters, config);
    }

    function testQuoteFailuresArmThenEmergencyExpiresToNormal() public {
        vm.startPrank(reporter);
        manager.recordQuoteFailure();
        manager.recordQuoteFailure();
        vm.stopPrank();

        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(manager.armedReasonFlags(), manager.TRIGGER_QUOTE_FAILURE());

        vm.prank(multisig);
        manager.activateEmergency();

        assertTrue(manager.isEmergencyActive());

        vm.warp(block.timestamp + 3 days + 1);

        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.NORMAL));
        assertFalse(manager.isEmergencyActive());

        manager.syncState();
        assertEq(manager.armedReasonFlags(), 0);
    }

    function testSwapFailuresArmEmergency() public {
        vm.startPrank(reporter);
        manager.recordSwapFailure();
        manager.recordSwapFailure();
        vm.stopPrank();

        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(manager.armedReasonFlags(), manager.TRIGGER_SWAP_FAILURE());
    }

    function testEndpointFailureArmsEmergency() public {
        vm.prank(reporter);
        manager.recordEndpointFailure();

        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(manager.armedReasonFlags(), manager.TRIGGER_ENDPOINT_FAILURE());
        assertEq(manager.endpointFailureCount(), 1);
    }

    function testOnlyReporterCanRecordFailures() public {
        vm.expectRevert(EmergencyManager.NotAuthorizedReporter.selector);
        manager.recordSwapFailure();
    }

    function testReporterRegistrarCanAuthorizeVaultReporter() public {
        address vault = address(0xCAFE);

        vm.prank(reporterRegistrar);
        manager.setReporter(vault, true);

        assertTrue(manager.isReporter(vault));
    }

    function testOnlyReporterRegistrarCanAuthorizeVaultReporter() public {
        vm.expectRevert(EmergencyManager.NotReporterRegistrar.selector);
        manager.setReporter(address(0xCAFE), true);
    }
}
