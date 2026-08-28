// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFundraisingToken is IERC20 {
    function burnFromVault(uint256 amount) external;
}
