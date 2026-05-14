// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";

/**
 * @title EmergencyManager
 * @notice Tracks objective protocol failures and controls the global emergency state.
 * @dev Authorized protocol components report consecutive quote, swap, and endpoint failures. Once a configured
 * threshold is reached, the contract moves from NORMAL to ARMED. The emergency multisig may then activate a
 * time-bounded EMERGENCY_ACTIVE window. The manager does not independently reproduce failures; reporter access
 * should be limited to contracts that directly observe the failure.
 */
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
        uint64 endpointFailureThreshold;
    }

    struct FailureCounters {
        uint64 consecutive;
    }

    address public immutable emergencyMultisig;
    address public immutable reporterRegistrar;
    uint256 public immutable emergencyDuration;
    uint256 public immutable quoteFailureThreshold;
    uint256 public immutable swapFailureThreshold;
    uint256 public immutable endpointFailureThreshold;

    EmergencyState internal emergencyState;
    uint256 public emergencyExpiresAt;
    uint256 public armedReasonFlags;

    FailureCounters public quoteFailures;
    FailureCounters public swapFailures;
    FailureCounters public endpointFailures;

    mapping(address => bool) public isReporter;

    event EmergencyArmed(uint256 triggerFlags, uint64 consecutiveQuoteFailures, uint64 consecutiveSwapFailures);
    event EmergencyActivated(uint256 expiresAt);
    event EmergencyExited();
    event ReporterConfigured(address reporter, bool allowed);
    event EndpointFailureRecorded(IIntegrationRegistry.Endpoint endpoint);

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

    /**
     * @notice Deploys the emergency state machine.
     * @param _emergencyMultisig Address allowed to activate and close emergency mode after arming.
     * @param _reporterRegistrar Address allowed to add or remove failure reporters, normally the factory.
     * @param reporters Initial reporter addresses allowed to record failures.
     * @param config Emergency duration and consecutive failure thresholds.
     */
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
        endpointFailureThreshold = config.endpointFailureThreshold;

        emergencyState = EmergencyState.NORMAL;

        uint256 reportersLength = reporters.length;
        for (uint256 i; i < reportersLength; ++i) {
            address reporter = reporters[i];
            if (reporter == address(0)) revert ZeroAddress();
            isReporter[reporter] = true;
        }
    }

    /**
     * @notice Returns whether the protocol is currently inside an active emergency window.
     * @dev Expired emergency windows are treated as inactive even before `syncState` is called.
     */
    function isEmergencyActive() public view override returns (bool) {
        return _resolvedMode() == EmergencyState.EMERGENCY_ACTIVE;
    }

    /**
     * @notice Returns the resolved emergency state.
     * @dev If the active emergency window has expired, this view returns NORMAL without mutating storage.
     */
    function mode() external view override returns (EmergencyState) {
        return _resolvedMode();
    }

    /**
     * @notice Synchronizes stored state with time-based emergency expiry.
     * @return The current stored emergency state after expiry processing.
     */
    function syncState() external override returns (EmergencyState) {
        _syncState();
        return emergencyState;
    }

    /**
     * @notice Opens the emergency window after the system has been objectively armed.
     * @dev Callable only by the emergency multisig and only from ARMED state.
     */
    function activateEmergency() external override onlyEmergencyMultisig {
        _syncState();
        if (emergencyState != EmergencyState.ARMED) revert InvalidState();
        emergencyState = EmergencyState.EMERGENCY_ACTIVE;
        emergencyExpiresAt = block.timestamp + emergencyDuration;
        emit EmergencyActivated(emergencyExpiresAt);
    }

    /**
     * @notice Closes an active emergency window and resets failure counters and arming flags.
     * @dev Callable only by the emergency multisig while EMERGENCY_ACTIVE.
     */
    function closeEmergency() external override onlyEmergencyMultisig {
        _syncState();
        if (emergencyState != EmergencyState.EMERGENCY_ACTIVE) revert InvalidState();
        _resetToNormal();
        emit EmergencyExited();
    }

    /**
     * @notice Adds or removes an authorized reporter.
     * @param reporter Protocol component allowed or disallowed from recording failures.
     * @param allowed Whether the reporter should be authorized.
     */
    function setReporter(address reporter, bool allowed) external override onlyReporterRegistrar {
        if (reporter == address(0)) revert ZeroAddress();
        isReporter[reporter] = allowed;
        emit ReporterConfigured(reporter, allowed);
    }

    /**
     * @notice Records one quote failure for the calling reporter.
     * @dev Arms emergency once consecutive quote failures reach `quoteFailureThreshold`.
     */
    function recordQuoteFailure() public override onlyReporter {
        _syncState();
        _recordFailure(quoteFailures);
        if (quoteFailures.consecutive >= quoteFailureThreshold) {
            _armEmergency(TRIGGER_QUOTE_FAILURE);
        }
    }

    /**
     * @notice Resets the consecutive quote failure counter after a successful quote.
     */
    function recordQuoteSuccess() external onlyReporter {
        _syncState();
        quoteFailures.consecutive = 0;
    }

    /**
     * @notice Records one swap execution failure for the calling reporter.
     * @dev Arms emergency once consecutive swap failures reach `swapFailureThreshold`.
     */
    function recordSwapFailure() public override onlyReporter {
        _syncState();
        _recordFailure(swapFailures);
        if (swapFailures.consecutive >= swapFailureThreshold) {
            _armEmergency(TRIGGER_SWAP_FAILURE);
        }
    }

    /**
     * @notice Resets the consecutive swap failure counter after a successful swap.
     */
    function recordSwapSuccess() external onlyReporter {
        _syncState();
        swapFailures.consecutive = 0;
    }

    /**
     * @notice Records one endpoint failure for the calling reporter.
     * @param endpoint Numeric value of the IntegrationRegistry endpoint that failed.
     * @dev Emits the failing endpoint and arms emergency once consecutive endpoint failures reach threshold.
     */
    function recordEndpointFailure(uint8 endpoint) external override onlyReporter {
        _syncState();
        emit EndpointFailureRecorded(IIntegrationRegistry.Endpoint(endpoint));
        _recordFailure(endpointFailures);
        if (endpointFailures.consecutive >= endpointFailureThreshold) {
            _armEmergency(TRIGGER_ENDPOINT_FAILURE);
        }
    }

    /**
     * @notice Increments a consecutive failure counter.
     */
    function _recordFailure(FailureCounters storage counters) internal {
        unchecked {
            ++counters.consecutive;
        }
    }

    /**
     * @notice Adds a trigger flag and moves NORMAL to ARMED.
     * @dev Additional trigger flags can accumulate while already ARMED or EMERGENCY_ACTIVE.
     */
    function _armEmergency(uint256 triggerFlag) internal {
        armedReasonFlags |= triggerFlag;
        if (emergencyState == EmergencyState.NORMAL) {
            emergencyState = EmergencyState.ARMED;
            emit EmergencyArmed(armedReasonFlags, quoteFailures.consecutive, swapFailures.consecutive);
        }
    }

    /**
     * @notice Applies automatic expiry for active emergency windows.
     */
    function _syncState() internal {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            _resetToNormal();
            emit EmergencyExited();
        }
    }

    /**
     * @notice Resets the state machine and all tracked failure counters to NORMAL.
     */
    function _resetToNormal() internal {
        emergencyState = EmergencyState.NORMAL;
        emergencyExpiresAt = 0;
        armedReasonFlags = 0;
        quoteFailures.consecutive = 0;
        swapFailures.consecutive = 0;
        endpointFailures.consecutive = 0;
    }

    /**
     * @notice Resolves the current mode without mutating storage.
     */
    function _resolvedMode() internal view returns (EmergencyState) {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            return EmergencyState.NORMAL;
        }
        return emergencyState;
    }
}
