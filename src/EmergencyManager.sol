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
        uint64 swapFailureThreshold;
    }

    struct FailureCounters {
        uint64 consecutive;
    }

    address public immutable emergencyMultisig;
    address public immutable reporterRegistrar;
    uint256 public immutable emergencyDuration;
    uint256 public immutable quoteFailureThreshold;
    uint256 public immutable swapFailureThreshold;

    EmergencyState internal emergencyState;
    uint256 public emergencyExpiresAt;
    uint256 public armedReasonFlags;

    FailureCounters public quoteFailures;
    FailureCounters public swapFailures;

    mapping(address => bool) public isReporter;

    event EmergencyArmed(uint256 triggerFlags, uint64 consecutiveQuoteFailures, uint64 consecutiveSwapFailures);
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
        swapFailureThreshold = config.swapFailureThreshold;

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
        _recordFailure(quoteFailures);
        if (quoteFailureThreshold != 0 && quoteFailures.consecutive >= quoteFailureThreshold) {
            _armEmergency(TRIGGER_QUOTE_FAILURE);
        }
    }

    function recordQuoteSuccess() external onlyReporter syncBefore {
        quoteFailures.consecutive = 0;
    }

    function recordSwapFailure() public override onlyReporter syncBefore {
        _recordFailure(swapFailures);
        if (swapFailureThreshold != 0 && swapFailures.consecutive >= swapFailureThreshold) {
            _armEmergency(TRIGGER_SWAP_FAILURE);
        }
    }

    function recordSwapSuccess() external onlyReporter syncBefore {
        swapFailures.consecutive = 0;
    }

    function recordEndpointFailure() external override onlyReporter syncBefore {
        _armEmergency(TRIGGER_ENDPOINT_FAILURE);
    }

    function _recordFailure(FailureCounters storage counters) internal {
        unchecked {
            ++counters.consecutive;
        }
    }

    function _armEmergency(uint256 triggerFlag) internal {
        armedReasonFlags |= triggerFlag;
        if (emergencyState == EmergencyState.NORMAL) {
            emergencyState = EmergencyState.ARMED;
            emit EmergencyArmed(armedReasonFlags, quoteFailures.consecutive, swapFailures.consecutive);
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
        quoteFailures.consecutive = 0;
        swapFailures.consecutive = 0;
    }

    function _resolvedMode() internal view returns (EmergencyState) {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            return EmergencyState.NORMAL;
        }
        return emergencyState;
    }
}
