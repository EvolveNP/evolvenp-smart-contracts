// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";
import {IHookDeployer} from "./interfaces/IHookDeployer.sol";

/**
 * @title IntegrationRegistry
 * @notice Stores protocol integration endpoints and owns deployment of the shared fundraising hook.
 * @dev Mutable endpoint updates are allowed only during active emergency mode and only to previously allowed
 * contract addresses. PoolManager is immutable because live pools and the shared hook are bound to it.
 */
contract IntegrationRegistry is Ownable {
    enum Endpoint {
        ROUTER,
        PERMIT2,
        QUOTER,
        POOL_MANAGER,
        POSITION_MANAGER,
        STATE_VIEW,
        HOOK_DEPLOYER
    }

    error ZeroAddress();
    error EmergencyIsNotActive();
    error NotAllowedAtAddress();
    error NoCodeAtAddress();
    error ImmutableEndpoint();
    error HookAlreadyDeployed();
    error HookDeploymentFailed();

    address public router; // The address of the uniswap universal router
    address public permit2; // The address of the uniswap permit2 contract
    address public quoter; // The address of the uniswap v4 quoter
    address public immutable poolManager; // The address of the uniswap v4 pool manager
    address public positionManager; // The address of the uniswap v4 position manager
    address public stateView; // The address of the uniswap v4 state view
    address public hookDeployer; // The address of the hook deployer contract
    address public hookAddress; // The address of the shared fundraising hook
    address public emergencyManager; // The address of the emergency manager contract

    mapping(Endpoint => mapping(address => bool)) public isAllowedAddress; // Mapping to track allowed addresses for each integration type

    event AllowListConfigured(Endpoint endpointType, address allowedAddress, bool allowed);
    event IntegrationUpdated(Endpoint endpointType, address oldAddress, address newAddress);
    event HookDeployed(address hookAddress);

    /**
     * @notice Reverts when an address argument is zero.
     * @param _address Address to validate.
     */
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Deploys the registry with its initial integration endpoints.
     * @param _router Uniswap Universal Router endpoint.
     * @param _permit2 Permit2 endpoint.
     * @param _quoter Uniswap v4 quoter endpoint.
     * @param _poolManager Immutable Uniswap v4 PoolManager endpoint.
     * @param _positionManager Uniswap v4 position manager endpoint.
     * @param _stateView Uniswap v4 state view endpoint.
     * @param _hookDeployer HookDeployer used by this registry to deploy the shared hook.
     * @param _emergencyManager EmergencyManager that gates endpoint updates.
     */
    constructor(
        address _router,
        address _permit2,
        address _quoter,
        address _poolManager,
        address _positionManager,
        address _stateView,
        address _hookDeployer,
        address _emergencyManager
    )
        Ownable(msg.sender)
        nonZeroAddress(_router)
        nonZeroAddress(_permit2)
        nonZeroAddress(_quoter)
        nonZeroAddress(_poolManager)
        nonZeroAddress(_positionManager)
        nonZeroAddress(_stateView)
        nonZeroAddress(_hookDeployer)
        nonZeroAddress(_emergencyManager)
    {
        router = _router;
        permit2 = _permit2;
        quoter = _quoter;
        poolManager = _poolManager;
        positionManager = _positionManager;
        stateView = _stateView;
        hookDeployer = _hookDeployer;
        emergencyManager = _emergencyManager;
    }

    /**
     * @notice Updates a mutable integration endpoint during active emergency mode.
     * @param endpoint Endpoint type to update.
     * @param newAddress Replacement contract address. It must already be allowlisted for the endpoint.
     * @dev Reverts for POOL_MANAGER because it is immutable for a deployed protocol instance.
     */
    function updateIntegrationAddress(Endpoint endpoint, address newAddress)
        external
        onlyOwner
        nonZeroAddress(newAddress)
    {
        if (endpoint == Endpoint.POOL_MANAGER) revert ImmutableEndpoint();
        if (!isAllowedAddress[endpoint][newAddress]) revert NotAllowedAtAddress();
        if (!IEmergencyManager(emergencyManager).isEmergencyActive()) revert EmergencyIsNotActive();
        address currentAddress;
        if (endpoint == Endpoint.ROUTER) {
            currentAddress = router;
            router = newAddress;
        } else if (endpoint == Endpoint.PERMIT2) {
            currentAddress = permit2;
            permit2 = newAddress;
        } else if (endpoint == Endpoint.QUOTER) {
            currentAddress = quoter;
            quoter = newAddress;
        } else if (endpoint == Endpoint.POSITION_MANAGER) {
            currentAddress = positionManager;
            positionManager = newAddress;
        } else if (endpoint == Endpoint.STATE_VIEW) {
            currentAddress = stateView;
            stateView = newAddress;
        } else if (endpoint == Endpoint.HOOK_DEPLOYER) {
            currentAddress = hookDeployer;
            hookDeployer = newAddress;
        }

        emit IntegrationUpdated(endpoint, currentAddress, newAddress);
    }

    /**
     * @notice Adds or removes an allowed replacement address for an endpoint during active emergency mode.
     * @param endpoint Endpoint type whose allowlist is changed.
     * @param newAddress Contract address to allow or remove.
     * @param allowed Whether the address should be allowed.
     * @dev The address must contain code. POOL_MANAGER cannot be allowlisted because it cannot be updated.
     */
    function setAllowedAddress(Endpoint endpoint, address newAddress, bool allowed) external onlyOwner {
        if (endpoint == Endpoint.POOL_MANAGER) revert ImmutableEndpoint();
        if (newAddress.code.length == 0) revert NoCodeAtAddress();
        if (!IEmergencyManager(emergencyManager).isEmergencyActive()) revert EmergencyIsNotActive();
        isAllowedAddress[endpoint][newAddress] = allowed;
        emit AllowListConfigured(endpoint, newAddress, allowed);
    }

    /**
     * @notice Deploys the global fundraising hook once through the configured HookDeployer.
     * @param salt CREATE2 salt that produces a hook address with the required Uniswap v4 hook flags.
     * @return deployedHook The deployed shared hook address.
     * @dev Callable only by the registry owner. The stored hook cannot be replaced.
     */
    function deployHook(bytes32 salt) external onlyOwner returns (address deployedHook) {
        if (hookAddress != address(0)) revert HookAlreadyDeployed();
        try IHookDeployer(hookDeployer).deployHook(salt) returns (address hook) {
            hookAddress = hook;
            emit HookDeployed(hook);
            return hook;
        } catch {
            revert HookDeploymentFailed();
        }
    }
}
