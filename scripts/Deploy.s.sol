// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {EmergencyManager} from "../src/EmergencyManager.sol";
import {Factory} from "../src/Factory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {IntegrationRegistry} from "../src/IntegrationRegistry.sol";

contract DeployScript is Script {
    struct Deployment {
        address emergencyManager;
        address hookDeployer;
        address integrationRegistry;
        address factory;
        address hook;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        address router = vm.envAddress("ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address quoter = vm.envAddress("QUOTER");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address stateView = vm.envAddress("STATE_VIEW");
        address usdc = vm.envAddress("USDC");
        address emergencyMultisig = vm.envAddress("EMERGENCY_MULTISIG");

        EmergencyManager.Config memory emergencyConfig = EmergencyManager.Config({
            emergencyDuration: uint64(vm.envUint("EMERGENCY_DURATION")),
            quoteFailureThreshold: uint64(vm.envUint("QUOTE_FAILURE_THRESHOLD")),
            swapFailureThreshold: uint64(vm.envUint("SWAP_FAILURE_THRESHOLD")),
            endpointFailureThreshold: uint64(vm.envUint("ENDPOINT_FAILURE_THRESHOLD"))
        });

        uint64 nonce = vm.getNonce(deployer);
        address predictedEmergencyManager = _computeCreateAddress(deployer, nonce);
        address predictedHookDeployer = _computeCreateAddress(deployer, nonce + 1);
        address predictedIntegrationRegistry = _computeCreateAddress(deployer, nonce + 2);
        address predictedFactory = _computeCreateAddress(deployer, nonce + 3);

        address[] memory initialReporters = new address[](1);
        initialReporters[0] = predictedFactory;

        vm.startBroadcast(privateKey);

        EmergencyManager emergencyManager =
            new EmergencyManager(emergencyMultisig, predictedFactory, initialReporters, emergencyConfig);

        HookDeployer hookDeployer = new HookDeployer(predictedFactory, usdc, predictedIntegrationRegistry);

        IntegrationRegistry integrationRegistry = new IntegrationRegistry(
            router,
            permit2,
            quoter,
            poolManager,
            positionManager,
            stateView,
            address(hookDeployer),
            address(emergencyManager)
        );

        Factory factory = new Factory(address(integrationRegistry), address(emergencyManager), usdc);

        bytes32 hookSalt = hookDeployer.findSalt();
        address hook = integrationRegistry.deployHook(hookSalt);

        vm.stopBroadcast();

        require(address(emergencyManager) == predictedEmergencyManager, "emergency prediction mismatch");
        require(address(hookDeployer) == predictedHookDeployer, "hook deployer prediction mismatch");
        require(address(integrationRegistry) == predictedIntegrationRegistry, "registry prediction mismatch");
        require(address(factory) == predictedFactory, "factory prediction mismatch");

        deployment = Deployment({
            emergencyManager: address(emergencyManager),
            hookDeployer: address(hookDeployer),
            integrationRegistry: address(integrationRegistry),
            factory: address(factory),
            hook: hook
        });

        _saveDeployment(deployment, deployer, usdc);
        _logDeployment(deployment);
    }

    function _saveDeployment(Deployment memory deployment, address deployer, address usdc) internal {
        string memory chainDir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(chainDir, true);

        uint256 version = _nextVersion(chainDir);
        string memory json = "deployment";

        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "version", version);
        vm.serializeUint(json, "deployedAt", block.timestamp);
        vm.serializeAddress(json, "deployer", deployer);
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeAddress(json, "emergencyManager", deployment.emergencyManager);
        vm.serializeAddress(json, "hookDeployer", deployment.hookDeployer);
        vm.serializeAddress(json, "integrationRegistry", deployment.integrationRegistry);
        vm.serializeAddress(json, "factory", deployment.factory);
        string memory finalJson = vm.serializeAddress(json, "hook", deployment.hook);

        string memory versionPath = string.concat(chainDir, "/v", vm.toString(version), ".json");
        string memory latestPath = string.concat(chainDir, "/latest.json");

        vm.writeJson(finalJson, versionPath);
        vm.writeJson(finalJson, latestPath);
    }

    function _nextVersion(string memory chainDir) internal view returns (uint256 version) {
        version = 1;
        while (vm.exists(string.concat(chainDir, "/v", vm.toString(version), ".json"))) {
            ++version;
        }
    }

    function _logDeployment(Deployment memory deployment) internal view {
        console2.log("EmergencyManager:", deployment.emergencyManager);
        console2.log("HookDeployer:", deployment.hookDeployer);
        console2.log("IntegrationRegistry:", deployment.integrationRegistry);
        console2.log("Factory:", deployment.factory);
        console2.log("FundraisingTokenHook:", deployment.hook);
        console2.log("Deployment saved under deployments/%s/latest.json", vm.toString(block.chainid));
    }

    function _computeCreateAddress(address deployer, uint64 nonce) internal pure returns (address) {
        if (nonce == 0x00) {
            return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80))))));
        }
        if (nonce <= 0x7f) {
            return address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)))))
            );
        }
        if (nonce <= 0xff) {
            return address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce))))
                )
            );
        }
        if (nonce <= 0xffff) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce)))
                    )
                )
            );
        }
        if (nonce <= 0xffffff) {
            return address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce))
                        )
                    )
                )
            );
        }

        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce))))
            )
        );
    }
}
