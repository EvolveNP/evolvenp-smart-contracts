// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";

interface IAggregatorV3Like {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract EmergencyManager is IEmergencyManager {
    uint256 public constant TRIGGER_LIVENESS = 1 << 0;
    uint256 public constant TRIGGER_QUOTE_FAILURE = 1 << 1;
    uint256 public constant TRIGGER_SWAP_FAILURE = 1 << 2;
    uint256 public constant TRIGGER_ORACLE_INVALID = 1 << 3;
    uint256 public constant TRIGGER_ENDPOINT_INTEGRITY = 1 << 4;
    uint256 public constant TRIGGER_REENTRANCY = 1 << 5;
    uint256 public constant TRIGGER_INVARIANT = 1 << 6;

    error ZeroAddress();
    error NotAuthorizedReporter();
    error NotEmergencyMultisig();
    error InvalidState();
    error UnknownOracle();
    error UnknownEndpoint();

    struct Config {
        uint64 emergencyDuration;
        uint64 maxLivenessDelay;
        uint64 quoteFailureThreshold;
        uint64 quoteFailureWindow;
        uint64 quoteFailuresInWindowThreshold;
        uint64 swapFailureThreshold;
        uint64 swapFailureWindow;
        uint64 swapFailuresInWindowThreshold;
        uint64 oracleMaxStaleness;
        uint64 reentrancyTripThreshold;
        bool enforceEndpointCodehash;
    }

    struct EndpointConfig {
        address endpoint;
        bytes32[] allowedCodehashes;
    }

    struct FailureCounters {
        uint64 consecutive;
        uint64 inWindow;
        uint64 windowStart;
    }

    address public immutable emergencyMultisig;
    uint256 public immutable emergencyDuration;
    uint256 public immutable maxLivenessDelay;
    uint256 public immutable quoteFailureThreshold;
    uint256 public immutable quoteFailureWindow;
    uint256 public immutable quoteFailuresInWindowThreshold;
    uint256 public immutable swapFailureThreshold;
    uint256 public immutable swapFailureWindow;
    uint256 public immutable swapFailuresInWindowThreshold;
    uint256 public immutable oracleMaxStaleness;
    uint256 public immutable reentrancyTripThreshold;
    bool public immutable enforceEndpointCodehash;

    EmergencyState internal emergencyState;
    uint256 public emergencyExpiresAt;
    uint256 public lastSuccessAt;
    uint256 public armedReasonFlags;

    uint64 public oracleFailureCount;
    uint64 public endpointFailureCount;
    uint64 public reentrancyTripCount;
    uint64 public invariantFailureCount;

    FailureCounters public quoteFailures;
    FailureCounters public swapFailures;

    address[] public oracleFeeds;
    address[] public trackedEndpoints;

    mapping(address => bool) public isReporter;
    mapping(address => bool) public isTrackedOracle;
    mapping(address => bool) public isTrackedEndpoint;
    mapping(address => mapping(bytes32 => bool)) public isAllowedEndpointCodehash;

    event EmergencyArmed(
        uint256 triggerFlags,
        uint64 consecutiveQuoteFailures,
        uint64 quoteFailuresInWindow,
        uint64 consecutiveSwapFailures,
        uint64 swapFailuresInWindow,
        uint64 oracleFailures,
        uint64 endpointFailures,
        uint64 reentrancyTrips,
        uint64 invariantFailures,
        uint256 lastSuccessAt,
        address diagnosticAddress,
        bytes32 diagnosticTag
    );
    event EmergencyActivated(uint256 expiresAt);
    event EmergencyExited();

    modifier onlyReporter() {
        if (!isReporter[msg.sender]) revert NotAuthorizedReporter();
        _;
    }

    modifier onlyEmergencyMultisig() {
        if (msg.sender != emergencyMultisig) revert NotEmergencyMultisig();
        _;
    }

    modifier syncBefore() {
        _syncState();
        _;
    }

    constructor(
        address _emergencyMultisig,
        address[] memory reporters,
        Config memory config,
        address[] memory feeds,
        EndpointConfig[] memory endpoints
    ) {
        if (_emergencyMultisig == address(0)) revert ZeroAddress();
        if (config.emergencyDuration == 0 || config.maxLivenessDelay == 0) revert InvalidState();

        emergencyMultisig = _emergencyMultisig;
        emergencyDuration = config.emergencyDuration;
        maxLivenessDelay = config.maxLivenessDelay;
        quoteFailureThreshold = config.quoteFailureThreshold;
        quoteFailureWindow = config.quoteFailureWindow;
        quoteFailuresInWindowThreshold = config.quoteFailuresInWindowThreshold;
        swapFailureThreshold = config.swapFailureThreshold;
        swapFailureWindow = config.swapFailureWindow;
        swapFailuresInWindowThreshold = config.swapFailuresInWindowThreshold;
        oracleMaxStaleness = config.oracleMaxStaleness;
        reentrancyTripThreshold = config.reentrancyTripThreshold;
        enforceEndpointCodehash = config.enforceEndpointCodehash;

        emergencyState = EmergencyState.NORMAL;
        lastSuccessAt = block.timestamp;
        isReporter[_emergencyMultisig] = true;

        uint256 reportersLength = reporters.length;
        for (uint256 i; i < reportersLength; ++i) {
            address reporter = reporters[i];
            if (reporter == address(0)) revert ZeroAddress();
            isReporter[reporter] = true;
        }

        uint256 feedsLength = feeds.length;
        for (uint256 i; i < feedsLength; ++i) {
            address feed = feeds[i];
            if (feed == address(0)) revert ZeroAddress();
            if (isTrackedOracle[feed]) continue;
            isTrackedOracle[feed] = true;
            oracleFeeds.push(feed);
        }

        uint256 endpointsLength = endpoints.length;
        for (uint256 i; i < endpointsLength; ++i) {
            address endpoint = endpoints[i].endpoint;
            if (endpoint == address(0)) revert ZeroAddress();
            if (!isTrackedEndpoint[endpoint]) {
                isTrackedEndpoint[endpoint] = true;
                trackedEndpoints.push(endpoint);
            }

            uint256 hashesLength = endpoints[i].allowedCodehashes.length;
            for (uint256 j; j < hashesLength; ++j) {
                isAllowedEndpointCodehash[endpoint][endpoints[i].allowedCodehashes[j]] = true;
            }
        }
    }

    function isEmergencyActive() public view override returns (bool) {
        return _resolvedMode() == EmergencyState.EMERGENCY_ACTIVE;
    }

    function mode() external view override returns (EmergencyState) {
        return _resolvedMode();
    }

    function syncState() external returns (EmergencyState) {
        _syncState();
        return emergencyState;
    }

    function activateEmergency() external onlyEmergencyMultisig syncBefore {
        if (emergencyState != EmergencyState.ARMED) revert InvalidState();
        emergencyState = EmergencyState.EMERGENCY_ACTIVE;
        emergencyExpiresAt = block.timestamp + emergencyDuration;
        emit EmergencyActivated(emergencyExpiresAt);
    }

    function closeEmergency() external onlyEmergencyMultisig syncBefore {
        if (emergencyState != EmergencyState.EMERGENCY_ACTIVE) revert InvalidState();
        _resetToNormal();
        emit EmergencyExited();
    }

    function recordSuccessfulExecution() external onlyReporter syncBefore {
        lastSuccessAt = block.timestamp;
    }

    function recordQuoteFailure() public onlyReporter syncBefore {
        _recordFailure(quoteFailures, quoteFailureWindow);
        if (
            (quoteFailureThreshold != 0 && quoteFailures.consecutive >= quoteFailureThreshold)
                || (quoteFailuresInWindowThreshold != 0 && quoteFailures.inWindow >= quoteFailuresInWindowThreshold)
        ) {
            _armEmergency(TRIGGER_QUOTE_FAILURE, address(0), bytes32(0));
        }
    }

    function recordQuoteSuccess() external onlyReporter syncBefore {
        quoteFailures.consecutive = 0;
    }

    function recordSwapFailure() public onlyReporter syncBefore {
        _recordFailure(swapFailures, swapFailureWindow);
        if (
            (swapFailureThreshold != 0 && swapFailures.consecutive >= swapFailureThreshold)
                || (swapFailuresInWindowThreshold != 0 && swapFailures.inWindow >= swapFailuresInWindowThreshold)
        ) {
            _armEmergency(TRIGGER_SWAP_FAILURE, address(0), bytes32(0));
        }
    }

    function recordSwapSuccess() external onlyReporter syncBefore {
        swapFailures.consecutive = 0;
    }

    function recordReentrancyTrip() external onlyReporter syncBefore {
        unchecked {
            ++reentrancyTripCount;
        }
        if (reentrancyTripThreshold != 0 && reentrancyTripCount >= reentrancyTripThreshold) {
            _armEmergency(TRIGGER_REENTRANCY, address(0), bytes32(0));
        }
    }

    function recordInvariantViolation(bytes32 invariantId, uint256 lhs, uint256 rhs, bool expectedLte)
        external
        onlyReporter
        syncBefore
    {
        bool violated = expectedLte ? lhs > rhs : lhs < rhs;
        if (!violated) return;

        unchecked {
            ++invariantFailureCount;
        }
        _armEmergency(TRIGGER_INVARIANT, address(0), invariantId);
    }

    function checkLiveness() public syncBefore returns (bool) {
        if (block.timestamp > lastSuccessAt + maxLivenessDelay) {
            _armEmergency(TRIGGER_LIVENESS, address(0), bytes32(0));
            return true;
        }
        return false;
    }

    function checkOracle(address feed) public syncBefore returns (bool) {
        if (!isTrackedOracle[feed]) revert UnknownOracle();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3Like(feed).latestRoundData();
        if (
            updatedAt == 0 || answer <= 0 || answeredInRound < roundId
                || (oracleMaxStaleness != 0 && block.timestamp - updatedAt > oracleMaxStaleness)
        ) {
            unchecked {
                ++oracleFailureCount;
            }
            _armEmergency(TRIGGER_ORACLE_INVALID, feed, bytes32(uint256(updatedAt)));
            return true;
        }
        return false;
    }

    function checkAllOracles() external syncBefore returns (bool) {
        uint256 length = oracleFeeds.length;
        for (uint256 i; i < length; ++i) {
            if (checkOracle(oracleFeeds[i])) return true;
        }
        return false;
    }

    function checkEndpoint(address endpoint) public syncBefore returns (bool) {
        if (!isTrackedEndpoint[endpoint]) revert UnknownEndpoint();

        if (endpoint.code.length == 0) {
            unchecked {
                ++endpointFailureCount;
            }
            _armEmergency(TRIGGER_ENDPOINT_INTEGRITY, endpoint, bytes32(0));
            return true;
        }

        bytes32 codehash = endpoint.codehash;
        if (enforceEndpointCodehash && !isAllowedEndpointCodehash[endpoint][codehash]) {
            unchecked {
                ++endpointFailureCount;
            }
            _armEmergency(TRIGGER_ENDPOINT_INTEGRITY, endpoint, codehash);
            return true;
        }

        return false;
    }

    function checkAllEndpoints() external syncBefore returns (bool) {
        uint256 length = trackedEndpoints.length;
        for (uint256 i; i < length; ++i) {
            if (checkEndpoint(trackedEndpoints[i])) return true;
        }
        return false;
    }

    function checkLivelinessFailure() external override {
        checkLiveness();
    }

    function checkQuoteFailure() external override {
        recordQuoteFailure();
    }

    function checkSwapExecutionFailure() external override {
        recordSwapFailure();
    }

    function checkOracleFailure() external override {
        this.checkAllOracles();
    }

    function checkEndpointFailure() external override {
        this.checkAllEndpoints();
    }

    function checkInternalInvariantFailure() external override onlyReporter syncBefore {
        unchecked {
            ++invariantFailureCount;
        }
        _armEmergency(TRIGGER_INVARIANT, address(0), bytes32("LEGACY_INVARIANT"));
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

    function _armEmergency(uint256 triggerFlag, address diagnosticAddress, bytes32 diagnosticTag) internal {
        armedReasonFlags |= triggerFlag;
        if (emergencyState == EmergencyState.NORMAL) {
            emergencyState = EmergencyState.ARMED;
            emit EmergencyArmed(
                armedReasonFlags,
                quoteFailures.consecutive,
                quoteFailures.inWindow,
                swapFailures.consecutive,
                swapFailures.inWindow,
                oracleFailureCount,
                endpointFailureCount,
                reentrancyTripCount,
                invariantFailureCount,
                lastSuccessAt,
                diagnosticAddress,
                diagnosticTag
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
        quoteFailures.consecutive = 0;
        quoteFailures.inWindow = 0;
        quoteFailures.windowStart = 0;
        swapFailures.consecutive = 0;
        swapFailures.inWindow = 0;
        swapFailures.windowStart = 0;
        oracleFailureCount = 0;
        endpointFailureCount = 0;
        reentrancyTripCount = 0;
        invariantFailureCount = 0;
    }

    function _resolvedMode() internal view returns (EmergencyState) {
        if (emergencyState == EmergencyState.EMERGENCY_ACTIVE && block.timestamp >= emergencyExpiresAt) {
            return EmergencyState.NORMAL;
        }
        return emergencyState;
    }
}
