// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title IFactory
 * @notice Read interface used by hooks, vaults, and integrations to resolve protocol state.
 */
interface IFactory {
    /// @notice Stored state for a fundraising token protocol.
    struct FundraisingProtocol {
        address fundraisingToken; // The address of the fundraising token
        address underlyingAddress; // The USDC token used as the underlying asset
        address vault; // The vault that receives tax and distributes monthly proceeds
        address hook; // The shared hook used by the canonical pool
        bool isLPCreated; // Whether the canonical Uniswap v4 pool has been created
    }

    /**
     * @notice Returns protocol state for a fundraising token.
     * @param _owner Historical parameter name; interpreted as fundraising token address.
     */
    function getProtocol(address _owner) external view returns (FundraisingProtocol memory);

    /**
     * @notice Returns the canonical pool key for a fundraising token.
     * @param _fundraisingTokenAddress Fundraising token used as the protocol key.
     */
    function getPoolKeys(address _fundraisingTokenAddress) external view returns (PoolKey memory);

    /**
     * @notice Checks whether a pool key and hook are authorized for a fundraising token.
     * @param fundraisingToken Fundraising token used as the protocol key.
     * @param key Pool key being checked by the hook.
     * @param hookAddress Hook address expected on the pool key.
     */
    function isAuthorizedHookPool(address fundraisingToken, PoolKey calldata key, address hookAddress)
        external
        view
        returns (bool);
}
