// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IHookDeployer {
    function deployHook(bytes32 salt) external returns (address);
    function findSalt() external view returns (bytes32);
}
