// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/**
 * @title IIntegrationRegistry
 * @notice Read interface for current protocol integration endpoints.
 */
interface IIntegrationRegistry {
    /// @notice Integration endpoints tracked by the registry and emergency reports.
    enum Endpoint {
        ROUTER,
        PERMIT2,
        QUOTER,
        POOL_MANAGER,
        POSITION_MANAGER,
        STATE_VIEW,
        HOOK_DEPLOYER
    }

    /// @notice Current Uniswap Universal Router endpoint.
    function router() external view returns (address);

    /// @notice Current Permit2 endpoint.
    function permit2() external view returns (address);

    /// @notice Current Uniswap v4 quoter endpoint.
    function quoter() external view returns (address);

    /// @notice Immutable Uniswap v4 PoolManager endpoint.
    function poolManager() external view returns (address);

    /// @notice Current Uniswap v4 position manager endpoint.
    function positionManager() external view returns (address);

    /// @notice Current Uniswap v4 StateView endpoint.
    function stateView() external view returns (address);

    /// @notice Current hook deployer endpoint.
    function hookDeployer() external view returns (address);

    /// @notice One-time deployed shared fundraising hook.
    function hookAddress() external view returns (address);

    /// @notice EmergencyManager used to gate endpoint updates.
    function emergencyManager() external view returns (address);

    /// @notice Legacy codehash allowlist view retained for compatibility with older integrations.
    function isAllowedCodehash(Endpoint endpoint, bytes32 codehash) external view returns (bool);
}
