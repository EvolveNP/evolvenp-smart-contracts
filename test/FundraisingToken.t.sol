// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {FundRaisingToken} from "../src/FundraisingToken.sol";

contract FundraisingTokenTest is Test {
    FundRaisingToken public token;

    address public lpManager = address(0x1);
    address public treasury = address(0x2);
    uint256 public initialSupply = 1000 * 10 ** 18;

    function setUp() public {
        token = new FundRaisingToken("FundRaisingToken", "FRT", 18, lpManager, treasury, initialSupply);
    }
}
