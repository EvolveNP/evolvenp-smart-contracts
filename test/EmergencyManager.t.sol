// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {EmergencyManager} from "../src/EmergencyManager.sol";
import {IEmergencyManager} from "../src/interfaces/IEmergencyManager.sol";

contract MockOracleFeed {
    uint80 internal roundId;
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    function setRoundData(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint80 _answeredInRound) external {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

contract MockEndpoint {
    function ping() external pure returns (bool) {
        return true;
    }
}

contract EmergencyManagerTest is Test {
    address internal multisig = address(0xA11CE);
    address internal reporter = address(0xB0B);

    MockOracleFeed internal feed;
    MockEndpoint internal endpoint;
    EmergencyManager internal manager;

    function setUp() public {
        feed = new MockOracleFeed();
        endpoint = new MockEndpoint();
        feed.setRoundData(1, 1e8, block.timestamp, 1);

        address[] memory reporters = new address[](1);
        reporters[0] = reporter;

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);

        bytes32[] memory allowedHashes = new bytes32[](1);
        allowedHashes[0] = address(endpoint).codehash;

        EmergencyManager.EndpointConfig[] memory endpoints = new EmergencyManager.EndpointConfig[](1);
        endpoints[0] = EmergencyManager.EndpointConfig({endpoint: address(endpoint), allowedCodehashes: allowedHashes});

        EmergencyManager.Config memory config = EmergencyManager.Config({
            emergencyDuration: 3 days,
            maxLivenessDelay: 30 days,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3,
            oracleMaxStaleness: 1 days,
            reentrancyTripThreshold: 2,
            enforceEndpointCodehash: true
        });

        manager = new EmergencyManager(multisig, reporters, config, feeds, endpoints);
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

    function testLivenessCheckArmsWhenExecutionIsOverdue() public {
        vm.warp(block.timestamp + 30 days + 1);

        bool armed = manager.checkLiveness();

        assertTrue(armed);
        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(manager.armedReasonFlags(), manager.TRIGGER_LIVENESS());
    }

    function testOracleCheckArmsOnStaleData() public {
        vm.warp(3 days);
        feed.setRoundData(2, 1e8, block.timestamp - 2 days, 2);

        bool armed = manager.checkOracle(address(feed));

        assertTrue(armed);
        assertEq(uint256(manager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(manager.armedReasonFlags(), manager.TRIGGER_ORACLE_INVALID());
    }

    function testEndpointCheckArmsWhenTrackedEndpointHasNoCode() public {
        address missingEndpoint = address(0xCAFE);

        address[] memory reporters = new address[](1);
        reporters[0] = reporter;

        address[] memory feeds = new address[](0);

        EmergencyManager.EndpointConfig[] memory endpoints = new EmergencyManager.EndpointConfig[](1);
        endpoints[0] = EmergencyManager.EndpointConfig({endpoint: missingEndpoint, allowedCodehashes: new bytes32[](0)});

        EmergencyManager.Config memory config = EmergencyManager.Config({
            emergencyDuration: 1 days,
            maxLivenessDelay: 30 days,
            quoteFailureThreshold: 2,
            quoteFailureWindow: 1 days,
            quoteFailuresInWindowThreshold: 3,
            swapFailureThreshold: 2,
            swapFailureWindow: 1 days,
            swapFailuresInWindowThreshold: 3,
            oracleMaxStaleness: 1 days,
            reentrancyTripThreshold: 0,
            enforceEndpointCodehash: false
        });

        EmergencyManager missingCodeManager = new EmergencyManager(multisig, reporters, config, feeds, endpoints);

        bool armed = missingCodeManager.checkEndpoint(missingEndpoint);

        assertTrue(armed);
        assertEq(uint256(missingCodeManager.mode()), uint256(IEmergencyManager.EmergencyState.ARMED));
        assertEq(missingCodeManager.armedReasonFlags(), missingCodeManager.TRIGGER_ENDPOINT_INTEGRITY());
    }

    function testOnlyReporterCanRecordFailures() public {
        vm.expectRevert(EmergencyManager.NotAuthorizedReporter.selector);
        manager.recordSwapFailure();
    }
}
