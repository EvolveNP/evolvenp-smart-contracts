// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Helper} from "../src/libraries/Helper.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract HelperWrapper {
    function encodeSqrtPriceX96(uint256 amount1, uint256 amount0) external pure returns (uint160) {
        return Helper.encodeSqrtPriceX96(amount1, amount0);
    }

    function getMinAndMaxTick(uint160 sqrtPriceX96, int24 defaultTickSpacing)
        external
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return Helper.getMinAndMaxTick(sqrtPriceX96, defaultTickSpacing);
    }
}

contract HelperTest is Test {
    HelperWrapper internal helper;

    function setUp() public {
        helper = new HelperWrapper();
    }

    function testEncodeSqrtPriceX96ForParityPrice() public view {
        uint160 sqrtPriceX96 = helper.encodeSqrtPriceX96(1e18, 1e18);
        assertEq(sqrtPriceX96, uint160(1 << 96));
    }

    function testEncodeSqrtPriceX96ForHigherPrice() public view {
        uint160 sqrtPriceX96 = helper.encodeSqrtPriceX96(4e18, 1e18);
        assertEq(sqrtPriceX96, uint160(2 << 96));
    }

    function testGetMinAndMaxTickForParityPrice() public view {
        uint160 sqrtPriceX96 = uint160(1 << 96);
        int24 spacing = 60;

        (int24 tickLower, int24 tickUpper) = helper.getMinAndMaxTick(sqrtPriceX96, spacing);

        assertEq(tickLower, -600000);
        assertEq(tickUpper, 600000);
    }

    function testGetMinAndMaxTickRoundsAroundCurrentTick() public view {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(121);
        int24 spacing = 10;

        (int24 tickLower, int24 tickUpper) = helper.getMinAndMaxTick(sqrtPriceX96, spacing);

        assertEq(tickLower, -99880);
        assertEq(tickUpper, 100120);
    }
}
