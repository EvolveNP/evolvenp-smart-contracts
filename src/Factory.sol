// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

contract Factory {
    address public immutable registryAddress;
    address public immutable emergencyManagerAddress;

    constructor(address _registryAddress, address _emergencyManagerAddress) {
        registryAddress = _registryAddress;
        emergencyManagerAddress = _emergencyManagerAddress;
    }
}
