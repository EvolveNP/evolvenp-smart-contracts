// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FundraisingTokenHook} from "./FundraisingTokenHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IIntegrationRegistry} from "./interfaces/IIntegrationRegistry.sol";

/**
 * @title HookDeployer
 * @notice Deploys the single shared FundraisingTokenHook for the registry.
 * @dev The registry is the only allowed caller. The deployer reads PoolManager from IntegrationRegistry and bakes
 * factory, USDC, and registry addresses into the hook constructor. `findSalt` helps find a CREATE2 salt whose
 * resulting hook address has the Uniswap v4 permission bits required by the hook.
 */
contract HookDeployer {
    IIntegrationRegistry public integrationRegistry;
    address public factoryAddress;
    address public usdcAddress;
    address public registryAddress;
    uint256 internal constant MAX_SALT_SEARCH = 160_444;

    error onlyRegistryAllowed();
    error ZeroAddress();
    error SaltNotFound();

    /**
     * @notice Reverts when an address argument is zero.
     * @param addr Address to validate.
     */
    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Restricts hook deployment to the IntegrationRegistry.
     */
    modifier onlyRegistry() {
        if (msg.sender != registryAddress) {
            revert onlyRegistryAllowed();
        }
        _;
    }

    /**
     * @notice Deploys the hook deployer.
     * @param _factoryAddress Factory used by the hook to resolve protocol vaults.
     * @param _usdcAddress USDC token used by all fundraising pools.
     * @param _integrationRegistryAddress Registry that owns deployment and supplies endpoints.
     */
    constructor(address _factoryAddress, address _usdcAddress, address _integrationRegistryAddress)
        nonZeroAddress(_factoryAddress)
        nonZeroAddress(_usdcAddress)
        nonZeroAddress(_integrationRegistryAddress)
    {
        factoryAddress = _factoryAddress;
        usdcAddress = _usdcAddress;
        registryAddress = _integrationRegistryAddress;
        integrationRegistry = IIntegrationRegistry(_integrationRegistryAddress);
    }

    /**
     * @notice Deploys the shared FundraisingTokenHook using CREATE2.
     * @param salt Salt selected to produce a valid Uniswap v4 hook address.
     * @return Address of the deployed hook.
     */
    function deployHook(bytes32 salt) external onlyRegistry returns (address) {
        address poolManager = integrationRegistry.poolManager();

        FundraisingTokenHook hook = new FundraisingTokenHook{salt: salt}(
            poolManager, factoryAddress, usdcAddress, address(integrationRegistry)
        );
        return address(hook);
    }

    /**
     * @notice Computes and returns a CREATE2 salt that will produce a valid hook deployment address
     *         matching the required Uniswap V4 hook flag bitmask for the global fundraising hook.
     *
     * @dev This function does not deploy the hook. It searches deterministic salts against this deployer,
     * current registry endpoints, and current constructor arguments.
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
        flags = flags & Hooks.ALL_HOOK_MASK;

        address poolManager = integrationRegistry.poolManager();
        bytes memory constructorArgs =
            abi.encode(poolManager, factoryAddress, usdcAddress, address(integrationRegistry));
        bytes32 creationCodeHash = keccak256(abi.encodePacked(type(FundraisingTokenHook).creationCode, constructorArgs));

        for (uint256 salt; salt < MAX_SALT_SEARCH; ++salt) {
            address hookAddress = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xFF), address(this), bytes32(salt), creationCodeHash)))
                )
            );

            if ((uint160(hookAddress) & Hooks.ALL_HOOK_MASK) == flags && hookAddress.code.length == 0) {
                return bytes32(salt);
            }
        }

        revert SaltNotFound();
    }
}
