// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IEmergencyManager {
    enum EmergencyState {
        NORMAL,
        ARMED,
        EMERGENCY_ACTIVE
    }

    function isEmergencyActive() external view returns (bool);

    function mode() external view returns (EmergencyState);

    function armedReasonFlags() external view returns (uint256);

    function lastSuccessAt() external view returns (uint256);

    function activateEmergency() external;

    function closeEmergency() external;

    function syncState() external returns (EmergencyState);

    function recordSuccessfulExecution() external;

    function recordQuoteFailure() external;

    function recordQuoteSuccess() external;

    function recordSwapFailure() external;

    function recordSwapSuccess() external;

    function recordReentrancyTrip() external;

    function recordInvariantViolation(bytes32 invariantId, uint256 lhs, uint256 rhs, bool expectedLte) external;

    function checkLiveness() external returns (bool);

    function checkOracle(address feed) external returns (bool);

    function checkAllOracles() external returns (bool);

    function checkEndpoint(address endpoint) external returns (bool);

    function checkAllEndpoints() external returns (bool);

    function checkLivelinessFailure() external;

    function checkQuoteFailure() external;

    function checkSwapExecutionFailure() external;

    function checkOracleFailure() external;

    function checkEndpointFailure() external;

    function checkInternalInvariantFailure() external;
}
