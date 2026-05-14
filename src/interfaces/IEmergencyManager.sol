// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/**
 * @title IEmergencyManager
 * @notice Interface for the global emergency state machine and failure reporter API.
 */
interface IEmergencyManager {
    /// @notice Emergency lifecycle states.
    enum EmergencyState {
        NORMAL,
        ARMED,
        EMERGENCY_ACTIVE
    }

    /// @notice Returns true only while an unexpired emergency window is active.
    function isEmergencyActive() external view returns (bool);

    /// @notice Returns the resolved emergency state.
    function mode() external view returns (EmergencyState);

    /// @notice Returns the accumulated trigger flags that armed the system.
    function armedReasonFlags() external view returns (uint256);

    /// @notice Opens the emergency window after the system has reached ARMED state.
    function activateEmergency() external;

    /// @notice Closes active emergency mode and resets failure counters.
    function closeEmergency() external;

    /// @notice Adds or removes an authorized failure reporter.
    function setReporter(address reporter, bool allowed) external;

    /// @notice Applies time-based expiry and returns the stored state.
    function syncState() external returns (EmergencyState);

    /// @notice Records an endpoint failure for an authorized reporter.
    function recordEndpointFailure(uint8 endpoint) external;

    /// @notice Records a quote failure for an authorized reporter.
    function recordQuoteFailure() external;

    /// @notice Resets consecutive quote failures after a successful quote.
    function recordQuoteSuccess() external;

    /// @notice Records a swap failure for an authorized reporter.
    function recordSwapFailure() external;

    /// @notice Resets consecutive swap failures after a successful swap.
    function recordSwapSuccess() external;
}
