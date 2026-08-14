// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {FundraisingToken} from "../FundraisingToken.sol";
import {VaultV2} from "../VaultV2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

library FactoryLibrary {
    error ZeroAddress();
    error ZeroAmount();
    error InvalidVrfConfig();

    struct DeployFundraisingVaultParams {
        string tokenName;
        string tokenSymbol;
        address underlyingAddress;
        address[] beneficiaries;
        uint256 intervalSeconds;
        address registryAddress;
        address emergencyManager;
        uint256 minTokenBalanceToExecute;
        address factory;
        address vrfCoordinator;
        bytes32 vrfKeyHash;
        uint64 vrfSubscriptionId;
        uint16 vrfRequestConfirmations;
        uint32 vrfCallbackGasLimit;
        uint256 totalSupply;
        uint8 decimals;
    }

    function requireNonZeroAddress(address target) external pure {
        if (target == address(0)) revert ZeroAddress();
    }

    function requireNonZeroAmount(uint256 amount) external pure {
        if (amount == 0) revert ZeroAmount();
    }

    function requireValidVrfConfig(VaultV2.VrfConfig memory vrfConfig) external pure {
        if (vrfConfig.coordinator == address(0)) revert ZeroAddress();
        if (vrfConfig.subscriptionId == 0) revert InvalidVrfConfig();
        if (vrfConfig.requestConfirmations == 0) revert InvalidVrfConfig();
        if (vrfConfig.callbackGasLimit == 0) revert InvalidVrfConfig();
    }

    function deployFundraisingVault(DeployFundraisingVaultParams memory params)
        external
        returns (address vaultAddress, address fundraisingTokenAddress)
    {
        VaultV2 vault = new VaultV2(
            params.underlyingAddress,
            params.intervalSeconds,
            params.beneficiaries,
            params.registryAddress,
            params.emergencyManager,
            params.minTokenBalanceToExecute,
            params.factory,
            VaultV2.VrfConfig({
                coordinator: params.vrfCoordinator,
                keyHash: params.vrfKeyHash,
                subscriptionId: params.vrfSubscriptionId,
                requestConfirmations: params.vrfRequestConfirmations,
                callbackGasLimit: params.vrfCallbackGasLimit
            })
        );

        FundraisingToken fundraisingToken = new FundraisingToken(
            params.tokenName,
            params.tokenSymbol,
            params.decimals,
            params.factory,
            address(vault),
            params.totalSupply * 10 ** params.decimals
        );

        vault.setFundraisingToken(address(fundraisingToken));
        return (address(vault), address(fundraisingToken));
    }

    function getModifyLiqiuidityParams(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        uint160 startingPrice
    ) external view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        int24 maxTickSpacing = TickMath.MAX_TICK_SPACING;
        int24 tickLower = TickMath.minUsableTick(maxTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(maxTickSpacing);

        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(startingPrice, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1);

        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0, amount1, 0xdead, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);

        return abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, params), block.timestamp + 1000
        );
    }
}
