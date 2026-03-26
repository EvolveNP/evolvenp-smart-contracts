// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IEmergencyManager} from "./interfaces/IEmergencyManager.sol";

contract IntegrationRegistry is Ownable {
    enum Endpoint {
        ROUTER,
        PERMIT2,
        QUOTER,
        POOL_MANAGER,
        POSITION_MANAGER,
        STATE_VIEW
    }

    error ZeroAddress();
    error EmergencyIsNotActive();
    error NotAllowedAtAddress();
    error NoCodeAtAddress();

    address public router; // The address of the uniswap universal router
    address public permit2; // The address of the uniswap permit2 contract
    address public quoter; // The address of the uniswap v4 quoter
    address public poolManager; // The address of the uniswap v4 pool manager
    address public positionManager; // The address of the uniswap v4 position manager
    address public stateView; // The address of the uniswap v4 state view
    address public emergencyManager; // The address of the emergency manager contract

    mapping(Endpoint => mapping(address => bool)) public isAllowedAddress; // Mapping to track allowed addresses for each integration type

    event AllowListConfigured(Endpoint endpointType, address allowedAddress, bool allowed);
    event IntegrationUpdated(Endpoint endpointType, address oldAddress, address newAddress);

    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    constructor(
        address _router,
        address _permit2,
        address _quoter,
        address _poolManager,
        address _positionManager,
        address _stateView,
        address _emergencyManager
    )
        Ownable(msg.sender)
        nonZeroAddress(_router)
        nonZeroAddress(_permit2)
        nonZeroAddress(_quoter)
        nonZeroAddress(_poolManager)
        nonZeroAddress(_positionManager)
        nonZeroAddress(_stateView)
        nonZeroAddress(_emergencyManager)
    {
        router = _router;
        permit2 = _permit2;
        quoter = _quoter;
        poolManager = _poolManager;
        positionManager = _positionManager;
        stateView = _stateView;
        emergencyManager = _emergencyManager;
    }

    function updateIntegrationAddress(Endpoint endpoint, address newAddress)
        external
        onlyOwner
        nonZeroAddress(newAddress)
    {
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
        } else if (endpoint == Endpoint.POOL_MANAGER) {
            currentAddress = poolManager;
            poolManager = newAddress;
        } else if (endpoint == Endpoint.POSITION_MANAGER) {
            currentAddress = positionManager;
            positionManager = newAddress;
        } else if (endpoint == Endpoint.STATE_VIEW) {
            currentAddress = stateView;
            stateView = newAddress;
        }

        emit IntegrationUpdated(endpoint, currentAddress, newAddress);
    }

    function setAllowedAddress(Endpoint endpoint, address newAddress, bool allowed) external onlyOwner {
        if (newAddress.code.length == 0) revert NoCodeAtAddress();
        isAllowedAddress[endpoint][newAddress] = allowed;
        emit AllowListConfigured(endpoint, newAddress, allowed);
    }
}
