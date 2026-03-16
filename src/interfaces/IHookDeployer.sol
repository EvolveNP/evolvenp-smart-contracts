// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

interface IHookDeployer {
    function deployHook(
        address poolManager,
        address fundraisingToken,
        address treasuryWallet,
        address donationWallet,
        address router,
        address quoter,
        address stateView,
        bytes32 salt
    ) external returns (address);
}
