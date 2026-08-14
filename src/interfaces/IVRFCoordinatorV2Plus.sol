// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/**
 * @notice Minimal Chainlink VRF V2 coordinator interface used by this Vault.
 * @dev Kept local so the repository can compile offline without adding a Chainlink package dependency.
 */
interface IVRFCoordinatorV2 {
    /**
     * @notice Requests verifiable randomness from Chainlink VRF.
     * @param keyHash Gas lane key hash configured for the target network.
     * @param subId Chainlink VRF subscription id that funds the request.
     * @param minimumRequestConfirmations Number of block confirmations before fulfillment.
     * @param callbackGasLimit Gas available to the fulfillment callback.
     * @param numWords Number of random words requested.
     * @return requestId Chainlink VRF request identifier.
     */
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}
