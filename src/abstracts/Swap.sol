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

/**
 * @title Swap
 * @notice Shared Uniswap v4 quote and swap helper for protocol contracts.
 * @dev Reads router, quoter, and Permit2 endpoints from IntegrationRegistry at call time. The helper supports
 * exact-input swaps through Universal Router and applies a fixed 5% slippage buffer to quotes.
 */
abstract contract Swap {
    uint256 public constant slippage = 5e16; // 5%
    IIntegrationRegistry public immutable integrationRegistry; // The address of the integration registry contract

    error ZeroAddress();
    error ZeroAmount();

    /**
     * @notice Reverts when an address argument is zero.
     * @param _address Address to validate.
     */
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert ZeroAddress();
        _;
    }

    /**
     * @notice Sets the IntegrationRegistry used for Uniswap endpoints.
     * @param _integrationRegistry Registry address.
     */
    constructor(address _integrationRegistry) nonZeroAddress(_integrationRegistry) {
        integrationRegistry = IIntegrationRegistry(_integrationRegistry);
    }

    /**
     * @notice Executes an exact-input Uniswap v4 swap through Universal Router.
     * @param key Pool key to swap against.
     * @param amountIn Exact input amount.
     * @param minAmountOut Minimum accepted output amount.
     * @param _isCurrency0FundraisingToken Whether currency0 is the input fundraising token.
     * @return amountOut Actual output amount received by this contract.
     */
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
        balanceBeforeSwap = _balanceOfCurrency(currencyOut);

        approveTokenWithPermit2(currencyInAddress, uint160(amountIn), uint48(deadline));

        (UniversalRouter(payable(integrationRegistry.router()))).execute(commands, inputs, deadline);

        balanceAfterSwap = _balanceOfCurrency(currencyOut);
        amountOut = balanceAfterSwap - balanceBeforeSwap;
    }

    /**
     * @notice Approves Permit2 and then approves the router through Permit2 for a swap.
     * @param token ERC20 input token.
     * @param amount Permit2 allowance amount.
     * @param expiration Permit2 allowance expiration timestamp.
     */
    function approveTokenWithPermit2(address token, uint160 amount, uint48 expiration) internal {
        IERC20(token).approve(address(integrationRegistry.permit2()), type(uint256).max);
        (IPermit2(integrationRegistry.permit2())).approve(token, integrationRegistry.router(), amount, expiration);
    }

    /**
     * @notice Quotes an exact-input swap and returns the minimum amount after slippage.
     * @param _key Pool key to quote against.
     * @param _zeroForOne Swap direction.
     * @param _exactAmount Exact input amount.
     * @param _hookData Hook data forwarded to the quoter.
     * @return minAmountAmount Minimum acceptable output after applying fixed slippage.
     */
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

    /**
     * @notice Returns this contract's balance for a Uniswap v4 currency.
     * @param currency Currency to inspect.
     */
    function _balanceOfCurrency(Currency currency) internal view returns (uint256) {
        return currency.balanceOf(address(this));
    }
}
