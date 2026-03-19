// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FundraisingToken} from "../src/FundraisingToken.sol";

contract FundraisingTokenTest is Test {
    FundraisingToken public token;

    address public lpManager = address(0x1);
    address public treasury = address(0x2);
    uint256 public initialSupply = 1000 * 10 ** 18;

    function setUp() public {
        token = new FundraisingToken("FundraisingToken", "FRT", 18, lpManager, treasury, initialSupply);
    }

    function testConstructorSetsMetadata() public view {
        assertEq(token.name(), "FundraisingToken");
        assertEq(token.symbol(), "FRT");
        assertEq(token.decimals(), 18);
    }

    function testConstructorSetsImmutableAddresses() public view {
        assertEq(token.lpManager(), lpManager);
        assertEq(token.treasuryAddress(), treasury);
    }

    function testConstructorDistributesInitialSupplySeventyFiveTwentyFive() public view {
        uint256 expectedLpAllocation = (initialSupply * 75e16) / 1e18;
        uint256 expectedTreasuryAllocation = (initialSupply * 25e16) / 1e18;

        assertEq(token.balanceOf(lpManager), expectedLpAllocation);
        assertEq(token.balanceOf(treasury), expectedTreasuryAllocation);
        assertEq(token.totalSupply(), expectedLpAllocation + expectedTreasuryAllocation);
        assertEq(token.totalSupply(), initialSupply);
    }

    function testConstructorRevertsWhenLpManagerIsZero() public {
        vm.expectRevert(FundraisingToken.ZeroAddress.selector);
        new FundraisingToken("FundraisingToken", "FRT", 18, address(0), treasury, initialSupply);
    }

    function testConstructorRevertsWhenTreasuryIsZero() public {
        vm.expectRevert(FundraisingToken.ZeroAddress.selector);
        new FundraisingToken("FundraisingToken", "FRT", 18, lpManager, address(0), initialSupply);
    }

    function testConstructorRevertsWhenInitialSupplyIsZero() public {
        vm.expectRevert(FundraisingToken.ZeroAmount.selector);
        new FundraisingToken("FundraisingToken", "FRT", 18, lpManager, treasury, 0);
    }

    function testConstructorSupportsCustomDecimals() public {
        FundraisingToken tokenWithSixDecimals =
            new FundraisingToken("FundraisingToken", "FRT", 6, lpManager, treasury, initialSupply);

        assertEq(tokenWithSixDecimals.decimals(), 6);
    }

    function testConstructorRevertsWhenLpManagerAndTreasuryAreSameAddress() public {
        address recipient = address(0xBEEF);
        vm.expectRevert(FundraisingToken.SameAddress.selector);
        new FundraisingToken("FundraisingToken", "FRT", 18, recipient, recipient, initialSupply);
    }

    function testConstructorRoundsDownTinySupply() public {
        FundraisingToken tinySupplyToken = new FundraisingToken("FundraisingToken", "FRT", 18, lpManager, treasury, 1);

        assertEq(tinySupplyToken.balanceOf(lpManager), 0);
        assertEq(tinySupplyToken.balanceOf(treasury), 0);
        assertEq(tinySupplyToken.totalSupply(), 0);
    }
}
