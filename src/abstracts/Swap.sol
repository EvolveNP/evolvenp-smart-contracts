// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IIntegrationRegistry} from "../interfaces/IIntegrationRegistry.sol";

abstract contract Swap {
    uint256 public constant slippage = 5e16; // 5%
    IIntegrationRegistry public immutable integrationRegistry; // The address of the integration registry contract

    error ZeroAddress();
    error ZeroAmount();

    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    constructor(address _integrationRegistry) nonZeroAddress(_integrationRegistry) {
        integrationRegistry = IIntegrationRegistry(_integrationRegistry);
    }

    function swapExactInputSingle(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        bool _isCurrency0FundraisingToken
    ) internal returns (uint256 amountOut) {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: _isCurrency0FundraisingToken,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );

        Currency currencyIn = _isCurrency0FundraisingToken ? key.currency0 : key.currency1;
        Currency currencyOut = _isCurrency0FundraisingToken ? key.currency1 : key.currency0;

        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(currencyOut, minAmountOut);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        address currencyInAddress = Currency.unwrap(currencyIn);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;

        uint256 balanceBeforeSwap;
        uint256 balanceAfterSwap;
        if (Currency.unwrap(currencyOut) == address(0)) {
            balanceBeforeSwap = address(this).balance;
        } else {
            balanceBeforeSwap = currencyOut.balanceOf(address(this));
        }

        approveTokenWithPermit2(currencyInAddress, uint160(amountIn), uint48(deadline));

        (UniversalRouter(payable(integrationRegistry.router()))).execute(commands, inputs, deadline);

        if (Currency.unwrap(currencyOut) == address(0)) {
            balanceAfterSwap = address(this).balance;
        } else {
            balanceAfterSwap = currencyOut.balanceOf(address(this));
        }
        amountOut = balanceAfterSwap - balanceBeforeSwap;
    }

    function approveTokenWithPermit2(address token, uint160 amount, uint48 expiration) internal {
        IERC20(token).approve(address(integrationRegistry.permit2()), type(uint256).max);
        (IPermit2(integrationRegistry.permit2())).approve(token, integrationRegistry.router(), amount, expiration);
    }

    function getMinAmountOut(PoolKey memory _key, bool _zeroForOne, uint128 _exactAmount, bytes memory _hookData)
        internal
        returns (uint256 minAmountAmount)
    {
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: _key, zeroForOne: _zeroForOne, exactAmount: _exactAmount, hookData: _hookData
        });

        (uint256 amountOut,) = (IV4Quoter(integrationRegistry.quoter())).quoteExactInputSingle(params);

        return (amountOut * (1e18 - slippage)) / 1e18;
    }
}
