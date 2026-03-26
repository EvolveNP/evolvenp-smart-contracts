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

    function activateEmergency() external;

    function closeEmergency() external;

    function setReporter(address reporter, bool allowed) external;

    function syncState() external returns (EmergencyState);

    function recordEndpointFailure() external;

    function recordQuoteFailure() external;

    function recordSwapFailure() external;
}
