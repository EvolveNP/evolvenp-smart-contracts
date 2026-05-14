// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IHook
 * @notice Minimal oracle read interface consumed by Vault.
 */
interface IHook {
    /**
     * @notice Returns oracle cumulative values for a pool.
     * @param key Pool key whose observations are read.
     * @param secondsAgos Lookback offsets.
     * @return tickCumulatives Tick cumulative values at the requested offsets.
     * @return secondsPerLiquidityCumulativeX128s Seconds-per-liquidity cumulative values.
     */
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /**
     * @notice Returns the current tick for a pool.
     * @param key Pool key to inspect.
     */
    function getCurrentTick(PoolKey calldata key) external view returns (int24);
}
