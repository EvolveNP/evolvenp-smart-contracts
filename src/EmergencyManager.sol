// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";

contract EmergencyManager is IEmergencyManager {
    uint256 public constant TRIGGER_QUOTE_FAILURE = 1 << 0;
    uint256 public constant TRIGGER_SWAP_FAILURE = 1 << 1;
    uint256 public constant TRIGGER_ENDPOINT_FAILURE = 1 << 2;

    error ZeroAddress();
    error NotAuthorizedReporter();
    error NotEmergencyMultisig();
    error NotReporterRegistrar();
    error InvalidState();

    struct Config {
        uint64 emergencyDuration;
        uint64 quoteFailureThreshold;
        uint64 quoteFailureWindow;
        uint64 quoteFailuresInWindowThreshold;
        uint64 swapFailureThreshold;
        uint64 swapFailureWindow;
        uint64 swapFailuresInWindowThreshold;
    }

    struct FailureCounters {
        uint64 consecutive;
        uint64 inWindow;
        uint64 windowStart;
    }

    address public immutable emergencyMultisig;
    address public immutable reporterRegistrar;
    uint256 public immutable emergencyDuration;
    uint256 public immutable quoteFailureThreshold;
    uint256 public immutable quoteFailureWindow;
    uint256 public immutable quoteFailuresInWindowThreshold;
    uint256 public immutable swapFailureThreshold;
    uint256 public immutable swapFailureWindow;
    uint256 public immutable swapFailuresInWindowThreshold;

    EmergencyState internal emergencyState;
    uint256 public emergencyExpiresAt;
    uint256 public armedReasonFlags;
    uint64 public endpointFailureCount;

    FailureCounters public quoteFailures;
    FailureCounters public swapFailures;

    mapping(address => bool) public isReporter;

    event EmergencyArmed(
        uint256 triggerFlags,
        uint64 endpointFailureCount,
        uint64 consecutiveQuoteFailures,
        uint64 quoteFailuresInWindow,
        uint64 consecutiveSwapFailures,
        uint64 swapFailuresInWindow
    );
    event EmergencyActivated(uint256 expiresAt);
    event EmergencyExited();
    event ReporterConfigured(address reporter, bool allowed);

    modifier onlyReporter() {
        if (!isReporter[msg.sender]) revert NotAuthorizedReporter();
        _;
    }

    modifier onlyEmergencyMultisig() {
        if (msg.sender != emergencyMultisig) revert NotEmergencyMultisig();
        _;
    }

    modifier onlyReporterRegistrar() {
        if (msg.sender != reporterRegistrar) revert NotReporterRegistrar();
        _;
    }

    modifier syncBefore() {
        _syncState();
        _;
    }

    //_reporterRegistrar -> Factory address
    constructor(
        address _emergencyMultisig,
        address _reporterRegistrar,
        address[] memory reporters,
        Config memory config
    ) {
        if (_emergencyMultisig == address(0) || _reporterRegistrar == address(0)) {
            revert ZeroAddress();
        }
        if (config.emergencyDuration == 0) revert InvalidState();

        emergencyMultisig = _emergencyMultisig;
        reporterRegistrar = _reporterRegistrar;
        emergencyDuration = config.emergencyDuration;
        quoteFailureThreshold = config.quoteFailureThreshold;
        quoteFailureWindow = config.quoteFailureWindow;
        quoteFailuresInWindowThreshold = config.quoteFailuresInWindowThreshold;
        swapFailureThreshold = config.swapFailureThreshold;
        swapFailureWindow = config.swapFailureWindow;
        swapFailuresInWindowThreshold = config.swapFailuresInWindowThreshold;

        emergencyState = EmergencyState.NORMAL;
        isReporter[_emergencyMultisig] = true;

        uint256 reportersLength = reporters.length;
        for (uint256 i; i < reportersLength; ++i) {
            address reporter = reporters[i];
            if (reporter == address(0)) revert ZeroAddress();
            isReporter[reporter] = true;
        }
    }

    function isEmergencyActive() public view override returns (bool) {
        return _resolvedMode() == EmergencyState.EMERGENCY_ACTIVE;
    }

    function mode() external view override returns (EmergencyState) {
        return _resolvedMode();
    }

    function syncState() external override returns (EmergencyState) {
        _syncState();
        return emergencyState;
    }

    function activateEmergency() external override onlyEmergencyMultisig syncBefore {
        if (emergencyState != EmergencyState.ARMED) revert InvalidState();
        emergencyState = EmergencyState.EMERGENCY_ACTIVE;
        emergencyExpiresAt = block.timestamp + emergencyDuration;
        emit EmergencyActivated(emergencyExpiresAt);
    }

    function closeEmergency() external override onlyEmergencyMultisig syncBefore {
        if (emergencyState != EmergencyState.EMERGENCY_ACTIVE) revert InvalidState();
        _resetToNormal();
        emit EmergencyExited();
    }

    function setReporter(address reporter, bool allowed) external override onlyReporterRegistrar {
        if (reporter == address(0)) revert ZeroAddress();
        isReporter[reporter] = allowed;
        emit ReporterConfigured(reporter, allowed);
    }

    function recordQuoteFailure() public override onlyReporter syncBefore {
        _recordFailure(quoteFailures, quoteFailureWindow);
        if (
            (quoteFailureThreshold != 0 && quoteFailures.consecutive >= quoteFailureThreshold)
                || (quoteFailuresInWindowThreshold != 0 && quoteFailures.inWindow >= quoteFailuresInWindowThreshold)
        ) {
            _armEmergency(TRIGGER_QUOTE_FAILURE);
        }
    }

    function recordSwapFailure() public override onlyReporter syncBefore {
        _recordFailure(swapFailures, swapFailureWindow);
        if (
            (swapFailureThreshold != 0 && swapFailures.consecutive >= swapFailureThreshold)
                || (swapFailuresInWindowThreshold != 0 && swapFailures.inWindow >= swapFailuresInWindowThreshold)
        ) {
            _armEmergency(TRIGGER_SWAP_FAILURE);
        }
    }

    function recordEndpointFailure() external override onlyReporter syncBefore {
        unchecked {
            ++endpointFailureCount;
        }
        _armEmergency(TRIGGER_ENDPOINT_FAILURE);
    }

    function _recordFailure(FailureCounters storage counters, uint256 window) internal {
        unchecked {
            ++counters.consecutive;
        }

        if (window == 0 || counters.windowStart == 0 || block.timestamp > counters.windowStart + window) {
            counters.windowStart = uint64(block.timestamp);
            counters.inWindow = 1;
            return;
        }

        unchecked {
            ++counters.inWindow;
        }
    }

    function _armEmergency(uint256 triggerFlag) internal {
        armedReasonFlags |= triggerFlag;
        if (emergencyState == EmergencyState.NORMAL) {
            emergencyState = EmergencyState.ARMED;
            emit EmergencyArmed(
                armedReasonFlags,
                endpointFailureCount,
                quoteFailures.consecutive,
                quoteFailures.inWindow,
                swapFailures.consecutive,
                swapFailures.inWindow
            );
        }
    }

    function _syncState() internal {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            _resetToNormal();
            emit EmergencyExited();
        }
    }

    function _resetToNormal() internal {
        emergencyState = EmergencyState.NORMAL;
        emergencyExpiresAt = 0;
        armedReasonFlags = 0;
        endpointFailureCount = 0;
        quoteFailures.consecutive = 0;
        quoteFailures.inWindow = 0;
        quoteFailures.windowStart = 0;
        swapFailures.consecutive = 0;
        swapFailures.inWindow = 0;
        swapFailures.windowStart = 0;
    }

    function _resolvedMode() internal view returns (EmergencyState) {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            return EmergencyState.NORMAL;
        }
        return emergencyState;
    }
}
