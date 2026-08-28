// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EmergencyManager} from "../src/EmergencyManager.sol";
import {Factory} from "../src/Factory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {IntegrationRegistry} from "../src/IntegrationRegistry.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {FactoryLibrary} from "../src/libraries/FactoryLibrary.sol";

/// @notice Testnet-only ERC20 used when a real USDC endpoint is not configured.
contract MockUSDC is ERC20 {
    uint8 internal constant TOKEN_DECIMALS = 6;

    constructor(address recipient, uint256 initialSupply) ERC20("Mock USD Coin", "mUSDC") {
        _mint(recipient, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }
}

/// @notice Deploys the full EvolveNP protocol and writes versioned deployment artifacts.
contract DeployProtocol is Script {
    struct CoreAddresses {
        address deployer;
        address usdc;
        address factoryLibrary;
        address emergencyManager;
        address integrationRegistry;
        address hookDeployer;
        address factory;
        address hook;
    }

    function run() external returns (CoreAddresses memory addresses) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        bool deployMockUsdc = vm.envOr("DEPLOY_MOCK_USDC", false) || usdc == address(0);

        uint64 nonce = vm.getNonce(deployer);
        if (deployMockUsdc) nonce++;
        address predictedFactoryLibrary = vm.computeCreateAddress(deployer, nonce++);
        address predictedEmergencyManager = vm.computeCreateAddress(deployer, nonce++);
        address predictedRegistry = vm.computeCreateAddress(deployer, nonce++);
        address predictedHookDeployer = vm.computeCreateAddress(deployer, nonce++);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce);

        vm.startBroadcast(privateKey);

        if (deployMockUsdc) {
            usdc = address(new MockUSDC(deployer, vm.envOr("MOCK_USDC_INITIAL_SUPPLY", uint256(1_000_000_000e6))));
        }

        address factoryLibrary = _deployFactoryLibrary();

        address emergencyMultisig = vm.envOr("EMERGENCY_MULTISIG", deployer);
        address[] memory reporters = new address[](0);
        EmergencyManager emergencyManager = new EmergencyManager(
            emergencyMultisig,
            predictedFactory,
            reporters,
            EmergencyManager.Config({
                emergencyDuration: uint64(vm.envOr("EMERGENCY_DURATION", uint256(7 days))),
                quoteFailureThreshold: uint64(vm.envOr("QUOTE_FAILURE_THRESHOLD", uint256(3))),
                swapFailureThreshold: uint64(vm.envOr("SWAP_FAILURE_THRESHOLD", uint256(3))),
                endpointFailureThreshold: uint64(vm.envOr("ENDPOINT_FAILURE_THRESHOLD", uint256(3)))
            })
        );

        IntegrationRegistry registry = new IntegrationRegistry(
            vm.envAddress("UNISWAP_ROUTER"),
            vm.envAddress("PERMIT2"),
            vm.envAddress("UNISWAP_V4_QUOTER"),
            vm.envAddress("UNISWAP_V4_POOL_MANAGER"),
            vm.envAddress("UNISWAP_V4_POSITION_MANAGER"),
            vm.envAddress("UNISWAP_V4_STATE_VIEW"),
            predictedHookDeployer,
            address(emergencyManager)
        );

        HookDeployer hookDeployer = new HookDeployer(predictedFactory, usdc, address(registry));

        Factory factory = new Factory(
            address(registry),
            address(emergencyManager),
            usdc,
            VaultV2.VrfConfig({
                coordinator: vm.envAddress("VRF_COORDINATOR"),
                keyHash: vm.envBytes32("VRF_KEY_HASH"),
                subscriptionId: uint64(vm.envUint("VRF_SUBSCRIPTION_ID")),
                requestConfirmations: uint16(vm.envOr("VRF_REQUEST_CONFIRMATIONS", uint256(3))),
                callbackGasLimit: uint32(vm.envOr("VRF_CALLBACK_GAS_LIMIT", uint256(500_000)))
            }),
            VaultV2.SlotConfig({
                slotsPerWindow: uint8(vm.envOr("SLOTS_PER_WINDOW", uint256(4))),
                firstEventStartSlot: uint8(vm.envOr("FIRST_EVENT_START_SLOT", uint256(0))),
                firstEventEndSlot: uint8(vm.envOr("FIRST_EVENT_END_SLOT", uint256(1))),
                secondEventStartSlot: uint8(vm.envOr("SECOND_EVENT_START_SLOT", uint256(2))),
                secondEventEndSlot: uint8(vm.envOr("SECOND_EVENT_END_SLOT", uint256(3)))
            })
        );

        address hook;
        if (vm.envOr("DEPLOY_SHARED_HOOK", false)) {
            bytes32 salt = hookDeployer.findSalt();
            hook = registry.deployHook(salt);
        }

        vm.stopBroadcast();

        addresses = CoreAddresses({
            deployer: deployer,
            usdc: usdc,
            factoryLibrary: factoryLibrary,
            emergencyManager: address(emergencyManager),
            integrationRegistry: address(registry),
            hookDeployer: address(hookDeployer),
            factory: address(factory),
            hook: hook
        });

        require(factoryLibrary == predictedFactoryLibrary, "factory library prediction mismatch");
        require(address(emergencyManager) == predictedEmergencyManager, "emergency manager prediction mismatch");
        require(address(registry) == predictedRegistry, "registry prediction mismatch");
        require(address(hookDeployer) == predictedHookDeployer, "hook deployer prediction mismatch");
        require(address(factory) == predictedFactory, "factory prediction mismatch");

        _writeDeployment(addresses, deployMockUsdc);
        _logDeployment(addresses, deployMockUsdc);
    }

    function _deployFactoryLibrary() internal returns (address deployed) {
        bytes memory bytecode = type(FactoryLibrary).creationCode;
        assembly ("memory-safe") {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "factory library deploy failed");
    }

    function _writeDeployment(CoreAddresses memory addresses, bool deployedMockUsdc) internal {
        string memory version = vm.envOr("DEPLOYMENT_VERSION", vm.toString(block.timestamp));
        string memory chainDir = string.concat("deployments/", vm.toString(block.chainid));
        string memory versionPath = string.concat(chainDir, "/", version, ".json");
        string memory latestPath = string.concat(chainDir, "/latest.json");

        vm.createDir(chainDir, true);

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeString(json, "version", version);
        vm.serializeUint(json, "deployedAt", block.timestamp);
        vm.serializeAddress(json, "deployer", addresses.deployer);
        vm.serializeBool(json, "deployedMockUsdc", deployedMockUsdc);
        vm.serializeAddress(json, "usdc", addresses.usdc);
        vm.serializeAddress(json, "factoryLibrary", addresses.factoryLibrary);
        vm.serializeAddress(json, "emergencyManager", addresses.emergencyManager);
        vm.serializeAddress(json, "integrationRegistry", addresses.integrationRegistry);
        vm.serializeAddress(json, "hookDeployer", addresses.hookDeployer);
        vm.serializeAddress(json, "factory", addresses.factory);
        string memory finalJson = vm.serializeAddress(json, "hook", addresses.hook);

        vm.writeJson(finalJson, versionPath);
        vm.writeJson(finalJson, latestPath);
    }

    function _logDeployment(CoreAddresses memory addresses, bool deployedMockUsdc) internal view {
        console2.log("Deployment saved under deployments/%s", vm.toString(block.chainid));
        console2.log("deployer", addresses.deployer);
        console2.log("deployedMockUsdc", deployedMockUsdc);
        console2.log("usdc", addresses.usdc);
        console2.log("factoryLibrary", addresses.factoryLibrary);
        console2.log("emergencyManager", addresses.emergencyManager);
        console2.log("integrationRegistry", addresses.integrationRegistry);
        console2.log("hookDeployer", addresses.hookDeployer);
        console2.log("factory", addresses.factory);
        console2.log("hook", addresses.hook);
    }
}
