// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IIntegrationRegistry {
    enum Endpoint {
        ROUTER,
        PERMIT2,
        QUOTER,
        POOL_MANAGER,
        POSITION_MANAGER,
        STATE_VIEW,
        HOOK_DEPLOYER
    }

    function router() external view returns (address);

    function permit2() external view returns (address);

    function quoter() external view returns (address);

    function poolManager() external view returns (address);

    function positionManager() external view returns (address);

    function stateView() external view returns (address);

    function hookDeployer() external view returns (address);

    function hookAddress() external view returns (address);

    function emergencyManager() external view returns (address);

    function isAllowedCodehash(Endpoint endpoint, bytes32 codehash) external view returns (bool);
}
