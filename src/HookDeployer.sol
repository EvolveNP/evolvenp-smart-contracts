// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FundraisingTokenHook} from "./FundraisingTokenHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";

contract HookDeployer {
    IIntegrationRegistry public integrationRegistry;
    address public factoryAddress;
    address public usdcAddress;

    error onlyFactoryAllowed();
    error ZeroAddress();

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factoryAddress) {
            revert onlyFactoryAllowed();
        }
        _;
    }

    constructor(address _factoryAddress, address _usdcAddress, address _integrationRegistryAddress)
        nonZeroAddress(_factoryAddress)
        nonZeroAddress(_usdcAddress)
        nonZeroAddress(_integrationRegistryAddress)
    {
        factoryAddress = _factoryAddress;
        usdcAddress = _usdcAddress;
        integrationRegistry = IIntegrationRegistry(_integrationRegistryAddress);
    }

    function deployHook(bytes32 salt) external onlyFactory returns (address) {
        address poolManager = integrationRegistry.poolManager();

        FundraisingTokenHook hook =
            new FundraisingTokenHook{salt: salt}(poolManager, factoryAddress, usdcAddress, address(integrationRegistry));
        return address(hook);
    }

    /**
     * @notice Computes and returns a CREATE2 salt that will produce a valid hook deployment address
     *         matching the required Uniswap V4 hook flag bitmask for the global fundraising hook.
     *
     * @dev This function performs an off-chain-compatible deterministic salt search using
     *      `HookMiner.find`. It does NOT deploy the hook contract — the returned salt must be supplied to
     *       the deployment function that performs the actual CREATE2 contract creation.
     *
     * @return salt The computed CREATE2 salt that results in a hook address whose lower bits satisfy
     *              the required Uniswap V4 hook flag constraints.
     */
    function findSalt() external view returns (bytes32) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        address poolManager = integrationRegistry.poolManager();
        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs =
            abi.encode(poolManager, factoryAddress, usdcAddress, address(integrationRegistry));
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FundraisingTokenHook).creationCode, constructorArgs);
        return salt;
    }
}
