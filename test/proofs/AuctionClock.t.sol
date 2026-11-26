// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Silo } from "../../src/Silo.sol";
import { ISilo } from "../../src/interfaces/ISilo.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { IMainnetSettlement } from "../../integration/mainnet/helpers/IMainnetSettlement.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

contract AuctionClockTest is Test {
    using GPv2Order for GPv2Order.Data;

    IMainnetSettlement internal settlement;
    Silo internal silo;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal resource;
    address internal recipient = makeAddr("recipient");

    function isSolver(address account) external view returns (bool) {
        return account == address(this);
    }

    function setUp() public {
        vm.skip(!vm.envOr("TEST_ISOLATED", false));
        settlement = IMainnetSettlement(
            deployCode(
                "lib/cowprotocol-contracts/deployments/mainnet/GPv2Settlement.json",
                abi.encode(address(this), address(0))
            )
        );
        tokenA = new MockERC20("Token A", "A");
        tokenB = new MockERC20("Token B", "B");
        resource = new MockERC20("Resource", "R");
        silo = new Silo(settlement, IERC20(address(resource)), recipient, 150, 100, 2 hours, address(this));
        tokenA.mint(address(silo), 10);
        tokenB.mint(address(silo), 20);
        resource.mint(address(settlement), 1_000);
        vm.warp(block.timestamp + 2 hours);
    }

    function testFilledOrderCannotBeCommittedAgain() public {
        GPv2Order.Data memory order = _order(tokenA, 100);
        _settle(order, true, "");
        tokenA.mint(address(silo), 10);
        vm.warp(block.timestamp + 1 minutes);
        _settle(order, false, abi.encodeWithSelector(ISilo.OrderAlreadyFilled.selector));
    }

    function testExpiredFillRecordCanBeClearedOnceCurveHasReachedFloor() public {
        GPv2Order.Data memory order = _order(tokenA, 100);
        order.validTo = uint32(block.timestamp + 2 hours);
        _settle(order, true, "");
        bytes[] memory uids = new bytes[](1);
        uids[0] = _uid(order);
        assertEq(settlement.filledAmount(uids[0]), 10);

        vm.warp(order.validTo - 1);
        assertEq(silo.currentMinimumBuyAmount(order.sellToken), 101);
        vm.warp(uint256(order.validTo) + 1);
        IMainnetSettlement.Interaction[][3] memory interactions;
        interactions[2] = new IMainnetSettlement.Interaction[](1);
        interactions[2][0] = IMainnetSettlement.Interaction(
            address(settlement), 0, abi.encodeWithSignature("freeFilledAmountStorage(bytes[])", uids)
        );
        settlement.settle(new IERC20[](0), new uint256[](0), new IMainnetSettlement.Trade[](0), interactions);
        assertEq(settlement.filledAmount(uids[0]), 0);
        tokenA.mint(address(silo), 11);
        _settle(_order(tokenA, 100), true, "");
        assertEq(resource.balanceOf(recipient), 200);
    }

    function testRevertedPayoutDoesNotResetClock() public {
        GPv2Order.Data memory order = _order(tokenA, 1_001);
        _settle(
            order,
            true,
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", address(settlement), 1_000, 1_001
            )
        );
        assertEq(settlement.filledAmount(_uid(order)), 0);
        _settle(_order(tokenA, 100), true, "");
        assertEq(resource.balanceOf(recipient), 100);
    }

    function testWireExpiryKeepsFiveMinuteExecutionWindow() public {
        GPv2Order.Data memory order = _order(tokenA, 100);
        uint32 lastExecution = uint32(block.timestamp + 5 minutes);
        uint32 validTo = order.validTo;
        order.validTo = validTo + 1;
        vm.expectRevert(ISilo.InvalidValidity.selector);
        silo.verify(order);
        _settle(order, false, abi.encodeWithSelector(ISilo.InvalidValidity.selector));

        order.validTo = validTo;
        silo.verify(order);
        vm.warp(lastExecution);
        silo.verify(order);
        vm.warp(uint256(lastExecution) + 1);
        vm.expectRevert(ISilo.InvalidValidity.selector);
        silo.verify(order);
        _settle(order, false, abi.encodeWithSelector(ISilo.InvalidValidity.selector));
    }

    function testCommitWithoutTradeLeavesFloor() public {
        GPv2Order.Data memory order = _order(tokenA, 100);
        _settle(order, false, "");
        assertEq(settlement.filledAmount(_uid(order)), 0);
        assertEq(tokenA.balanceOf(address(silo)), 10);
        _settle(order, true, "");
        assertEq(settlement.filledAmount(_uid(order)), 10);
        assertEq(resource.balanceOf(recipient), 100);
    }

    function testFullSaleRestartsOnlySoldTokenInSameBlock() public {
        uint256 saleBlock = block.number;
        uint256 saleTime = block.timestamp;
        GPv2Order.Data memory first = _order(tokenA, 100);
        _settle(first, true, "");
        assertFalse(silo.isCommitted(first.hash(settlement.domainSeparator())), "commit survived its transaction");
        assertEq(settlement.filledAmount(_uid(first)), 10);
        assertEq(tokenA.balanceOf(address(silo)), 0);
        tokenA.mint(address(silo), 11);

        GPv2Order.Data memory below = _order(tokenA, 100);
        _settle(below, true, abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, 100, 150));
        assertEq(settlement.filledAmount(_uid(below)), 0);
        assertEq(tokenA.balanceOf(address(silo)), 11);
        _settle(_order(tokenB, 100), true, "");
        _settle(_order(tokenA, 150), true, "");
        assertEq(resource.balanceOf(recipient), 350);
        assertEq(tokenB.balanceOf(address(silo)), 0);
        assertEq(tokenA.balanceOf(address(silo)), 0);
        assertEq(block.number, saleBlock);
        assertEq(block.timestamp, saleTime);
    }

    function testUnfilledCommitPreservesPreviousSaleTime() public {
        _settle(_order(tokenA, 100), true, "");
        tokenA.mint(address(silo), 11);
        uint256 saleTime = block.timestamp;
        vm.warp(saleTime + 10 minutes);
        assertEq(silo.currentMinimumBuyAmount(IERC20(address(tokenA))), 146);
        vm.warp(saleTime + 30 minutes);
        _settle(_order(tokenA, 138), false, "");
        vm.warp(saleTime + 40 minutes);
        _settle(_order(tokenA, 134), false, "");
        vm.warp(saleTime + 1 hours);
        _settle(_order(tokenA, 124), true, abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, 124, 125));
        _settle(_order(tokenA, 125), true, "");
        assertEq(resource.balanceOf(recipient), 225);
    }

    function testPersistentAttemptDoesNotAuthorizeNextTransaction() public {
        GPv2Order.Data memory order = _order(tokenA, 100);
        _settle(order, false, "");
        assertFalse(silo.isCommitted(order.hash(settlement.domainSeparator())));
        assertEq(silo.preparedBalance(OZIERC20(address(tokenA))), 0);
        bytes32 digest = order.hash(settlement.domainSeparator());
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(digest, abi.encode(order));
        vm.expectRevert(ISilo.InvalidCommitment.selector);
        this.prepareAndValidate(order);
        assertEq(silo.currentMinimumBuyAmount(order.sellToken), 100);
    }

    function prepareAndValidate(GPv2Order.Data calldata order) external returns (bytes4) {
        silo.prepare(OZIERC20(address(order.sellToken)));
        return silo.isValidSignature(order.hash(settlement.domainSeparator()), abi.encode(order));
    }

    function testPermissionlessPreparationDoesNotRestartFilledToken() public {
        _settle(_order(tokenA, 100), true, "");
        tokenA.mint(address(silo), 11);
        uint256 saleTime = block.timestamp;
        vm.warp(saleTime + 30 minutes);
        assertEq(silo.currentMinimumBuyAmount(IERC20(address(tokenA))), 138);
        silo.prepare(OZIERC20(address(tokenA)));
        assertEq(silo.currentMinimumBuyAmount(IERC20(address(tokenA))), 138);
        vm.warp(saleTime + 1 hours);
        silo.prepare(OZIERC20(address(tokenA)));
        assertEq(silo.currentMinimumBuyAmount(IERC20(address(tokenA))), 125);
    }

    function _order(MockERC20 token, uint256 buyAmount) internal view returns (GPv2Order.Data memory order) {
        order.sellToken = IERC20(address(token));
        order.buyToken = IERC20(address(resource));
        order.receiver = recipient;
        order.sellAmount = token.balanceOf(address(silo));
        order.buyAmount = buyAmount;
        order.validTo = uint32(block.timestamp + 2 hours + 5 minutes);
        order.appData = silo.appData(OZIERC20(address(token)));
        order.kind = GPv2Order.KIND_SELL;
        order.sellTokenBalance = GPv2Order.BALANCE_ERC20;
        order.buyTokenBalance = GPv2Order.BALANCE_ERC20;
    }

    function _uid(GPv2Order.Data memory order) internal view returns (bytes memory) {
        return abi.encodePacked(order.hash(settlement.domainSeparator()), address(silo), order.validTo);
    }

    function _settle(GPv2Order.Data memory order, bool trade, bytes memory expectedRevert) internal {
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = order.sellToken;
        tokens[1] = order.buyToken;
        uint256[] memory prices = new uint256[](2);
        prices[0] = order.buyAmount;
        prices[1] = order.sellAmount;
        IMainnetSettlement.Trade[] memory trades = new IMainnetSettlement.Trade[](trade ? 1 : 0);
        if (trade) {
            trades[0] = IMainnetSettlement.Trade({
                sellTokenIndex: 0,
                buyTokenIndex: 1,
                receiver: order.receiver,
                sellAmount: order.sellAmount,
                buyAmount: order.buyAmount,
                validTo: order.validTo,
                appData: order.appData,
                feeAmount: 0,
                flags: 0x40,
                executedAmount: order.sellAmount,
                signature: abi.encodePacked(address(silo), abi.encode(order))
            });
        }
        IMainnetSettlement.Interaction[][3] memory interactions;
        interactions[0] = new IMainnetSettlement.Interaction[](1);
        interactions[0][0] = IMainnetSettlement.Interaction(address(silo), 0, abi.encodeCall(silo.commit, (order)));
        if (expectedRevert.length != 0) vm.expectRevert(expectedRevert);
        settlement.settle(tokens, prices, trades, interactions);
    }
}
