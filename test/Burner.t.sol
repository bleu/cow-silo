// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { Burner } from "../src/Burner.sol";
import { IBurner } from "../src/interfaces/IBurner.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract BurnerTest is Test {
    MockERC20 internal token;
    Burner internal burner;

    function setUp() public {
        token = new MockERC20("Resource", "RSC");
        burner = new Burner(IERC20(address(token)));
    }

    function testBurnMovesCompleteBalanceToDeadAddress() public {
        token.mint(address(burner), 42 ether);
        assertEq(burner.burn(), 42 ether);
        assertEq(token.balanceOf(address(burner)), 0);
        assertEq(token.balanceOf(burner.DEAD()), 42 ether);
    }

    function testBurnRevertsOnEmptyBalance() public {
        vm.expectRevert(IBurner.EmptyBalance.selector);
        burner.burn();
    }

    function testConstructorRejectsZeroToken() public {
        vm.expectRevert(IBurner.ZeroAddress.selector);
        new Burner(IERC20(address(0)));
    }
}
