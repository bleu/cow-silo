// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ApprovalFundingAdapter } from "../src/ApprovalFundingAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract ApprovalFundingAdapterTest is Test {
    address internal source = makeAddr("source");
    address internal silo = makeAddr("silo");
    MockERC20 internal token;
    ApprovalFundingAdapter internal adapter;

    function setUp() public {
        token = new MockERC20("Collected", "FEE");
        adapter = new ApprovalFundingAdapter(source, silo);
    }

    function testFundRejectsCallerOtherThanSilo() public {
        token.mint(source, 60);
        vm.prank(source);
        token.approve(address(adapter), 60);

        vm.expectRevert(bytes4(keccak256("OnlySilo()")));
        adapter.fund(token);

        assertEq(token.balanceOf(source), 60);
        assertEq(token.balanceOf(silo), 0);
    }

    function testFundLeavesInventoryAboveAllowanceAtSource() public {
        token.mint(source, 100);
        vm.prank(source);
        token.approve(address(adapter), 60);

        vm.prank(silo);
        adapter.fund(token);

        assertEq(token.balanceOf(silo), 60);
        assertEq(token.balanceOf(source), 40);
    }

    function testAvailableBalanceReportsApprovedInventory() public {
        token.mint(source, 100);
        vm.prank(source);
        token.approve(address(adapter), 60);

        assertEq(adapter.availableBalance(token), 60);
    }

    function testFundSkipsZeroAvailableInventory() public {
        ZeroTransferRevertingToken strictToken = new ZeroTransferRevertingToken();
        strictToken.mint(source, 60);

        vm.prank(silo);
        adapter.fund(strictToken);

        assertEq(strictToken.balanceOf(source), 60);
        assertEq(strictToken.balanceOf(silo), 0);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        new ApprovalFundingAdapter(address(0), silo);

        vm.expectRevert(bytes4(keccak256("ZeroAddress()")));
        new ApprovalFundingAdapter(source, address(0));
    }

    function testFundUsesSourceBalanceWhenAllowanceIsLarger() public {
        token.mint(source, 60);
        vm.prank(source);
        token.approve(address(adapter), 100);

        assertEq(adapter.availableBalance(token), 60);
        vm.prank(silo);
        adapter.fund(token);

        assertEq(token.balanceOf(silo), 60);
        assertEq(token.balanceOf(source), 0);
        assertEq(token.allowance(source, address(adapter)), 40);
    }

    function testFundTransfersApprovedInventoryToSilo() public {
        token.mint(source, 60);
        vm.prank(source);
        token.approve(address(adapter), 60);

        vm.prank(silo);
        adapter.fund(token);

        assertEq(token.balanceOf(silo), 60);
        assertEq(token.balanceOf(source), 0);
    }
}

contract ZeroTransferRevertingToken is MockERC20 {
    constructor() MockERC20("Strict Collected", "STRICT") { }

    function _update(address from, address to, uint256 value) internal override {
        require(value != 0, "Zero transfer");
        super._update(from, to, value);
    }
}
