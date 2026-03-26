// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IHookDeployer {
    function deployHook(address fundraisingToken, address vault, bytes32 salt) external returns (address);
}
