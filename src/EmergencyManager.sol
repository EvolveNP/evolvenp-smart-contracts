// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {IEmergencyManager} from "./interface/IEmergencyManager.sol";

contract EmergencyManager is IEmergencyManager {
    error NotZeroValue();

    uint256 public emergencyWindowDuration; // Duration of the emergency window in seconds
    uint256 public emergencyWindowStart; // Timestamp when the emergency window starts
    EmergencyState internal emergencyState; // Current state of the emergency

    uint256 public maxLivelinessDelay; // Maximum allowed delay for liveliness checks in seconds

    uint256 public livelinessFailureCount; // Counter for liveliness failures
    uint256 public quoteFailureCount; // Counter for quote failures
    uint256 public swapExecutionFailureCount; // Counter for swap execution failures
    uint256 public oracleFailureCount; // Counter for oracle failures
    uint256 public endpointFailureCount; // Counter for endpoint failures
    uint256 public internalInvariantFailureCount; // Counter for internal invariant failures

    modifier nonZeroValue(uint256 value) {
        if (value == 0) revert NotZeroValue();
        _;
    }

    constructor(uint256 _emergencyWindowDuration, uint256 _maxLivelinessDelay)
        nonZeroValue(_emergencyWindowDuration)
        nonZeroValue(_maxLivelinessDelay)
    {
        emergencyWindowDuration = _emergencyWindowDuration;
        maxLivelinessDelay = _maxLivelinessDelay;
        emergencyState = EmergencyState.NORMAL;
    }

    function checkLivelinessFailure() external {
        livelinessFailureCount++;
    }

    function checkQuoteFailure() external {
        // This function would contain logic to check for on-chain conditions that indicate a failure in the quote mechanism.
        // If such conditions are detected, it would transition the emergencyState to ARMED.
        quoteFailureCount++;
    }

    function checkSwapExecutionFailure() external {
        // This function would contain logic to check for on-chain conditions that indicate a failure in swap execution.
        // If such conditions are detected, it would transition the emergencyState to ARMED.
        swapExecutionFailureCount++;
    }

    function checkOracleFailure() external {
        // This function would contain logic to check for on-chain conditions that indicate a failure in the oracle mechanism.
        // If such conditions are detected, it would transition the emergencyState to ARMED.
        oracleFailureCount++;
    }

    function checkEndpointFailure() external {
        // This function would contain logic to check for on-chain conditions that indicate a failure in the endpoint mechanism.
        // If such conditions are detected, it would transition the emergencyState to ARMED.
        endpointFailureCount++;
    }

    function checkInternalInvariantFailure() external {
        internalInvariantFailureCount++;
    }

    function isEmergencyActive() public view returns (bool) {
        if (emergencyState == EmergencyState.ACTIVE) {
            return true;
        }
        // TODO: check this
        if (emergencyState == EmergencyState.ARMED && block.timestamp >= emergencyWindowStart) {
            return true;
        }
        return false;
    }

    function mode() external view returns (EmergencyState) {
        return emergencyState;
    }
}
