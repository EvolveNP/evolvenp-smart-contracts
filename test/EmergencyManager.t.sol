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

    function testConstructorRejectsZeroAddresses() public {
        address[] memory reporters = new address[](0);
        EmergencyManager.Config memory config = EmergencyManager.Config({
            emergencyDuration: 3 days,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3
        });

        vm.expectRevert(EmergencyManager.ZeroAddress.selector);
        new EmergencyManager(address(0), reporterRegistrar, reporters, config);

        vm.expectRevert(EmergencyManager.ZeroAddress.selector);
        new EmergencyManager(multisig, address(0), reporters, config);
    }

    function testConstructorRejectsZeroDurationAndZeroReporterInList() public {
        address[] memory invalidReporters = new address[](1);
        invalidReporters[0] = address(0);

        EmergencyManager.Config memory invalidDuration = EmergencyManager.Config({
            emergencyDuration: 0,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3
        });

        vm.expectRevert(EmergencyManager.InvalidState.selector);
        new EmergencyManager(multisig, reporterRegistrar, new address[](0), invalidDuration);

        EmergencyManager.Config memory validDuration = EmergencyManager.Config({
            emergencyDuration: 3 days,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3
        });

        vm.expectRevert(EmergencyManager.ZeroAddress.selector);
        new EmergencyManager(multisig, reporterRegistrar, invalidReporters, validDuration);
    }

    function testEmergencyMultisigIsReporterByDefault() public view {
        assertTrue(manager.isReporter(multisig));
    }

    function testOnlyEmergencyMultisigCanActivateOrClose() public {
        vm.prank(reporter);
        manager.recordEndpointFailure();

        vm.expectRevert(EmergencyManager.NotEmergencyMultisig.selector);
        manager.activateEmergency();

        vm.expectRevert(EmergencyManager.NotEmergencyMultisig.selector);
        manager.closeEmergency();
    }

    function testActivateEmergencyRequiresArmedState() public {
        vm.prank(multisig);
        vm.expectRevert(EmergencyManager.InvalidState.selector);
        manager.activateEmergency();
    }

    function testCloseEmergencyRequiresActiveState() public {
        vm.prank(multisig);
        vm.expectRevert(EmergencyManager.InvalidState.selector);
        manager.closeEmergency();
    }

    function testCloseEmergencyResetsState() public {
        vm.prank(reporter);
        manager.recordEndpointFailure();

        vm.prank(multisig);
        manager.activateEmergency();

        vm.prank(multisig);
        manager.closeEmergency();

        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.NORMAL));
        assertEq(manager.armedReasonFlags(), 0);
        assertEq(manager.endpointFailureCount(), 0);
        assertEq(manager.emergencyExpiresAt(), 0);
        (uint64 quoteConsecutive, uint64 quoteInWindow, uint64 quoteWindowStart) = manager.quoteFailures();
        (uint64 swapConsecutive, uint64 swapInWindow, uint64 swapWindowStart) = manager.swapFailures();
        assertEq(quoteConsecutive, 0);
        assertEq(quoteInWindow, 0);
        assertEq(quoteWindowStart, 0);
        assertEq(swapConsecutive, 0);
        assertEq(swapInWindow, 0);
        assertEq(swapWindowStart, 0);
    }

    function testQuoteFailuresCanArmByWindowThreshold() public {
        address[] memory reporters = new address[](1);
        reporters[0] = reporter;

        EmergencyManager.Config memory config = EmergencyManager.Config({
            emergencyDuration: 3 days,
            quoteFailureThreshold: 0,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 2,
            swapFailureThreshold: 0,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 0
        });

        EmergencyManager windowManager = new EmergencyManager(multisig, reporterRegistrar, reporters, config);

        vm.startPrank(reporter);
        windowManager.recordQuoteFailure();
        windowManager.recordQuoteFailure();
        vm.stopPrank();

        assertEq(uint256(windowManager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(windowManager.armedReasonFlags(), windowManager.TRIGGER_QUOTE_FAILURE());
    }

    function testSwapFailureWindowResetsAfterWindowExpires() public {
        vm.prank(reporter);
        manager.recordSwapFailure();

        (uint64 consecutiveBefore, uint64 inWindowBefore,) = manager.swapFailures();
        assertEq(consecutiveBefore, 1);
        assertEq(inWindowBefore, 1);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(reporter);
        manager.recordSwapFailure();

        (uint64 consecutiveAfter, uint64 inWindowAfter, uint64 windowStartAfter) = manager.swapFailures();
        assertEq(consecutiveAfter, 2);
        assertEq(inWindowAfter, 1);
        assertEq(windowStartAfter, uint64(block.timestamp));
    }

    function testArmedReasonFlagsAccumulateAcrossTriggerTypes() public {
        vm.prank(reporter);
        manager.recordEndpointFailure();

        vm.startPrank(reporter);
        manager.recordQuoteFailure();
        manager.recordQuoteFailure();
        vm.stopPrank();

        uint256 expectedFlags = manager.TRIGGER_ENDPOINT_FAILURE() | manager.TRIGGER_QUOTE_FAILURE();
        assertEq(manager.armedReasonFlags(), expectedFlags);
    }

    function testSetReporterRejectsZeroAddressAndCanDisableReporter() public {
        vm.prank(reporterRegistrar);
        vm.expectRevert(EmergencyManager.ZeroAddress.selector);
        manager.setReporter(address(0), true);

        vm.prank(reporterRegistrar);
        manager.setReporter(reporter, false);
        assertFalse(manager.isReporter(reporter));

        vm.prank(reporter);
        vm.expectRevert(EmergencyManager.NotAuthorizedReporter.selector);
        manager.recordQuoteFailure();
    }
}
