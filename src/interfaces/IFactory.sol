// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IFactory {
    struct FundraisingProtocol {
        address fundraisingToken; // The address of the fundraising token
        address underlyingAddress; // The address of the underlying token (e.g., USDC, ETH)
        address vault; // the address of the treasury wallet
        address hook; // The address of the hook
        bool isLPCreated; // whether the lp is created or not
    }

    function getProtocol(address _owner) external view returns (FundraisingProtocol memory);
    function getPoolKeys(address _fundraisingTokenAddress) external view returns (PoolKey memory);
}
