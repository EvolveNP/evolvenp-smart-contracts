// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/**
 * @title IHookDeployer
 * @notice Interface for deploying the shared fundraising hook through IntegrationRegistry.
 */
interface IHookDeployer {
    /**
     * @notice Deploys the shared hook with a precomputed CREATE2 salt.
     * @param salt Salt that produces an address with the required Uniswap v4 hook flags.
     */
    function deployHook(bytes32 salt) external returns (address);

    /**
     * @notice Finds a salt that produces a valid hook address for the current constructor arguments.
     */
    function findSalt() external view returns (bytes32);
}
