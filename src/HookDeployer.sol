// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FundraisingTokenHook} from "./FundraisingTokenHook.sol";
import {IFactory} from "./interface/IFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IIntegrationRegistry} from "./interface/IIntegrationRegistry.sol";

contract HookDeployer is Ownable {
    IFactory public factory;
    IIntegrationRegistry public integrationRegistry;

    error ProtocolNotAvailable();
    error onlyFactoryAllowed();
    error ZeroAddress();

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) {
            revert onlyFactoryAllowed();
        }
        _;
    }

    constructor(address _factoryAddress, address _integrationRegistryAddress)
        nonZeroAddress(_factoryAddress)
        nonZeroAddress(_integrationRegistryAddress)
        Ownable(msg.sender)
    {
        factory = IFactory(_factoryAddress);
        integrationRegistry = IIntegrationRegistry(_integrationRegistryAddress);
    }

    function deployHook(
        address poolManager,
        address fundraisingToken,
        address treasuryWallet,
        address donationWallet,
        address router,
        address quoter,
        address stateView,
        bytes32 salt
    ) external onlyFactory returns (address) {
        FundraisingTokenHook hook = new FundraisingTokenHook{salt: salt}(
            poolManager, fundraisingToken, treasuryWallet, donationWallet, router, quoter, stateView
        );
        return address(hook);
    }

    /**
     * @notice Computes and returns a CREATE2 salt that will produce a valid hook deployment address
     *         matching the required Uniswap V4 hook flag bitmask for a specific non-profit protocol owner.
     *
     * @dev This function performs an off-chain-compatible deterministic salt search using
     *      `HookMiner.find`. It does NOT deploy the hook contract — the returned salt must be supplied to
     *       the deployment function that performs the actual CREATE2 contract creation.
     *
     *      The function reverts if no fundraising protocol has been initialized for the given owner.
     *
     * @param _nonProfitOrgOwner The address of the owner whose fundraising protocol configuration is used
     *                           to build constructor arguments for salt mining.
     *
     * @return salt The computed CREATE2 salt that results in a hook address whose lower bits satisfy
     *              the required Uniswap V4 hook flag constraints.
     */
    function findSalt(address _nonProfitOrgOwner) external view nonZeroAddress(_nonProfitOrgOwner) returns (bytes32) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        IFactory.FundraisingProtocol memory protocol = factory.getProtocol(_nonProfitOrgOwner);

        if (protocol.fundraisingToken == address(0)) revert ProtocolNotAvailable();
        address router = integrationRegistry.router();
        address quoter = integrationRegistry.quoter();
        address stateView = integrationRegistry.stateView();
        address poolManager = integrationRegistry.poolManager();
        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(
            poolManager,
            protocol.fundraisingToken,
            protocol.treasuryWallet,
            protocol.donationWallet,
            router,
            quoter,
            stateView
        );
        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FundraisingTokenHook).creationCode, constructorArgs);
        return salt;
    }
}
