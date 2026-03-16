// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {div, sqrt, UD60x18, wrap, unwrap} from "@prb/math/src/UD60x18.sol";

library Helper {
    function encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        // Compute price ratio as 60x18 fixed-point (safe high precision)
        UD60x18 ratio = div(wrap(amount1), wrap(amount0));

        // sqrt(ratio)
        uint256 sqrtRatio = unwrap(sqrt(ratio));

        // Scale sqrt(price) * 2^96 (convert from 1e18 scale to Q96)
        // Divide by 1e18 to normalize PRBMath scale
        uint256 sqrtX96 = (sqrtRatio * (1 << 96)) / 1e18;

        sqrtPriceX96 = uint160(sqrtX96);
    }

    function getMinAndMaxTick(uint160 _sqrtPriceX96, int24 _defaultTickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 currentTick = TickMath.getTickAtSqrtPrice(_sqrtPriceX96);
        tickLower = (currentTick / _defaultTickSpacing) * _defaultTickSpacing - _defaultTickSpacing * 10000;
        tickUpper = (currentTick / _defaultTickSpacing) * _defaultTickSpacing + _defaultTickSpacing * 10000;
    }
}
