// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IEmergencyManager {
    enum EmergencyState {
        NORMAL, // default operation mode
        ARMED, // Objective emergency conditions have been detected on-chain
        ACTIVE // Emergency window is open
    }

    function checkLivelinessFailure() external;

    function checkQuoteFailure() external;

    function checkSwapExecutionFailure() external;

    function checkOracleFailure() external;

    function checkEndpointFailure() external;

    function checkInternalInvariantFailure() external;

    function isEmergencyActive() external view returns (bool);

    function mode() external view returns (EmergencyState);
}
