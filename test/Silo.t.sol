// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { Silo } from "../src/Silo.sol";
import { ApprovalFundingAdapter } from "../src/ApprovalFundingAdapter.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import { ISilo } from "../src/interfaces/ISilo.sol";
import { IFundingAdapter } from "../src/interfaces/IFundingAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";
import {
    RevertingFundingAdapter,
    GasBurningFundingAdapter,
    LargeReturnDataFundingAdapter,
    TransferThenRevertFundingAdapter
} from "./mocks/MockFundingAdapter.sol";

contract SiloTest is Test {
    using GPv2Order for GPv2Order.Data;

    bytes32 internal constant APP_DATA = keccak256("cow-silo:test");
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow-silo:domain");
    uint256 internal constant MINIMUM_BUY_AMOUNT = 10;

    address internal vaultRelayer = makeAddr("vaultRelayer");
    address internal recipient = makeAddr("recipient");
    address internal owner = makeAddr("owner");

    MockSettlement internal settlement;
    MockERC20 internal resource;
    MockERC20 internal collected;
    MockERC20 internal collectedTwo;
    Silo internal silo;

    function setUp() public {
        settlement = new MockSettlement(DOMAIN_SEPARATOR, vaultRelayer);
        resource = new MockERC20("Resource", "RSC");
        collected = new MockERC20("Collected", "FEE");
        collectedTwo = new MockERC20("Collected Two", "FEE2");
        silo = new Silo(settlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, APP_DATA, owner);
        vm.warp(1_800_000_000);
    }

    function testConstructorSetsPermanentRules() public view {
        assertEq(address(silo.settlement()), address(settlement));
        assertEq(silo.vaultRelayer(), vaultRelayer);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
        assertEq(silo.minimumBuyAmount(), MINIMUM_BUY_AMOUNT);
        assertEq(silo.appData(), APP_DATA);
        assertEq(silo.domainSeparator(), DOMAIN_SEPARATOR);
        assertEq(silo.owner(), owner);
    }

    function testOwnerCanSetFundingAdapter() public {
        IFundingAdapter adapter = IFundingAdapter(makeAddr("fundingAdapter"));

        vm.expectEmit(true, true, false, true, address(silo));
        emit ISilo.FundingAdapterSet(address(0), address(adapter));
        vm.prank(owner);
        silo.setFundingAdapter(adapter);

        assertEq(address(silo.fundingAdapter()), address(adapter));
    }

    function testSetFundingAdapterRejectsUnauthorizedCaller() public {
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        silo.setFundingAdapter(IFundingAdapter(makeAddr("fundingAdapter")));
    }

    function testCommitFundsEmptySiloAndValidatesOrder() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 100);
        vm.prank(source);
        collected.approve(address(adapter), 100);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(100, 20);

        (bool observedCommitment, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertTrue(observedCommitment);
        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 0);
        assertEq(collected.balanceOf(address(silo)), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
    }

    function testCommitSellsCombinedInventory() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(address(silo), 40);
        collected.mint(source, 60);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(address(silo)), 100);
        assertEq(collected.balanceOf(source), 0);
    }

    function testCommitIgnoresFundingRevertForPrefundedOrder() public {
        RevertingFundingAdapter adapter = new RevertingFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitSurvivesAdapterExhaustingForwardedGas() public {
        GasBurningFundingAdapter adapter = new GasBurningFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.commitAndValidate{ gas: 500_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitIgnoresLargeAdapterReturnData() public {
        LargeReturnDataFundingAdapter adapter = new LargeReturnDataFundingAdapter(false);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.commitAndValidate{ gas: 350_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitIgnoresLargeAdapterRevertData() public {
        LargeReturnDataFundingAdapter adapter = new LargeReturnDataFundingAdapter(true);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.commitAndValidate{ gas: 350_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitBalanceMismatchRollsBackFunding() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(address(silo), 40);
        collected.mint(source, 60);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(99, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 99, 100));
        settlement.commitAndValidate(silo, digest, OZIERC20(address(collected)), 99, abi.encode(order));

        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
        assertEq(collected.allowance(source, address(adapter)), 60);
        assertEq(collected.allowance(address(silo), vaultRelayer), 0);
        assertFalse(silo.isCommitted(digest));
    }

    function testFundedOrderBelowMinimumRollsBackFunding() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 100);
        vm.prank(source);
        collected.approve(address(adapter), 100);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(100, MINIMUM_BUY_AMOUNT - 1);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        vm.expectRevert(
            abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, MINIMUM_BUY_AMOUNT - 1, MINIMUM_BUY_AMOUNT)
        );
        settlement.commitAndValidate(silo, digest, OZIERC20(address(collected)), 100, abi.encode(order));

        assertEq(collected.balanceOf(source), 100);
        assertEq(collected.balanceOf(address(silo)), 0);
        assertEq(collected.allowance(source, address(adapter)), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), 0);
        assertFalse(silo.isCommitted(digest));
    }

    function testCommitUsesReplacementAdapter() public {
        address oldSource = makeAddr("oldSource");
        address newSource = makeAddr("newSource");
        ApprovalFundingAdapter oldAdapter = new ApprovalFundingAdapter(oldSource, address(silo));
        ApprovalFundingAdapter newAdapter = new ApprovalFundingAdapter(newSource, address(silo));
        collected.mint(oldSource, 60);
        collected.mint(newSource, 80);
        vm.prank(oldSource);
        collected.approve(address(oldAdapter), 60);
        vm.prank(newSource);
        collected.approve(address(newAdapter), 80);
        vm.startPrank(owner);
        silo.setFundingAdapter(oldAdapter);
        silo.setFundingAdapter(newAdapter);
        vm.stopPrank();
        GPv2Order.Data memory order = validOrder(80, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 80, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(oldSource), 60);
        assertEq(collected.balanceOf(newSource), 0);
        assertEq(collected.balanceOf(address(silo)), 80);
    }

    function testCommitSkipsDisabledAdapter() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 60);
        collected.mint(address(silo), 40);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.startPrank(owner);
        silo.setFundingAdapter(adapter);
        silo.setFundingAdapter(IFundingAdapter(address(0)));
        vm.stopPrank();
        GPv2Order.Data memory order = validOrder(40, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
        assertEq(address(silo.fundingAdapter()), address(0));
    }

    function testAdapterRevertRollsBackItsTransferButNotCommitment() public {
        address source = makeAddr("source");
        TransferThenRevertFundingAdapter adapter = new TransferThenRevertFundingAdapter(source);
        collected.mint(source, 60);
        collected.mint(address(silo), 40);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(40, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.allowance(source, address(adapter)), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
    }

    function testCommitRejectsInsufficientBalanceAfterFundingFailure() public {
        RevertingFundingAdapter adapter = new RevertingFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 40);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 100, 40));
        settlement.commitAndValidate(silo, digest, OZIERC20(address(collected)), 100, abi.encode(order));

        assertFalse(silo.isCommitted(digest));
    }

    function testFuzzCommitCombinesExistingAndApprovedInventory(uint128 existing, uint128 approved) public {
        approved = uint128(bound(approved, 1, type(uint128).max));
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(address(silo), existing);
        collected.mint(source, uint256(approved) * 2);
        vm.prank(source);
        collected.approve(address(adapter), approved);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        uint256 amount = uint256(existing) + approved;
        GPv2Order.Data memory order = validOrder(amount, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), amount, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(address(silo)), amount);
        assertEq(collected.balanceOf(source), approved);
        assertEq(collected.allowance(source, address(adapter)), 0);
    }

    function testCommitValidatesPrefundedOrderWithoutSourceAllowance() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 60);
        collected.mint(address(silo), 40);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(40, 20);

        (, bytes4 result) = settlement.commitAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
    }

    function testCommitApprovesRelayerAndMakesSignatureValid() public {
        uint256 amount = 100 ether;
        collected.mint(address(silo), amount);
        GPv2Order.Data memory order = validOrder(amount, 9 ether);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        (bool observedCommitment, bytes4 result) =
            settlement.commitAndValidate(silo, digest, OZIERC20(address(collected)), amount, abi.encode(order));

        assertTrue(observedCommitment);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitmentStartsEmpty() public view {
        assertFalse(silo.isCommitted(keccak256("uncommitted order")));
    }

    function testCommitSupportsMultipleOrdersInOneSettlement() public {
        uint256 amountOne = 100 ether;
        uint256 amountTwo = 200 ether;
        collected.mint(address(silo), amountOne);
        collectedTwo.mint(address(silo), amountTwo);

        GPv2Order.Data memory orderOne = validOrder(address(collected), amountOne, 9 ether);
        GPv2Order.Data memory orderTwo = validOrder(address(collectedTwo), amountTwo, 12 ether);
        bytes32[2] memory digests = [orderOne.hash(DOMAIN_SEPARATOR), orderTwo.hash(DOMAIN_SEPARATOR)];
        OZIERC20[2] memory sellTokens = [OZIERC20(address(collected)), OZIERC20(address(collectedTwo))];
        uint256[2] memory sellAmounts = [amountOne, amountTwo];
        bytes[2] memory signatures = [abi.encode(orderOne), abi.encode(orderTwo)];

        (bool[2] memory observedCommitments, bytes4[2] memory results) =
            settlement.commitAndValidateTwo(silo, digests, sellTokens, sellAmounts, signatures);

        assertTrue(observedCommitments[0]);
        assertTrue(observedCommitments[1]);
        assertEq(results[0], IERC1271.isValidSignature.selector);
        assertEq(results[1], IERC1271.isValidSignature.selector);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(collectedTwo.allowance(address(silo), vaultRelayer), type(uint256).max);
    }

    function testCommitRevertsOutsideSettlement() public {
        collected.mint(address(silo), 1);
        vm.expectRevert(ISilo.CommitOutsideSettlement.selector);
        silo.commit(bytes32(uint256(1)), OZIERC20(address(collected)), 1);
    }

    function testCommitRevertsWhenBalanceChanged() public {
        collected.mint(address(silo), 10);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 11, 10));
        silo.commit(bytes32(uint256(1)), OZIERC20(address(collected)), 11);
    }

    function testCommitRejectsInvalidSellToken() public {
        vm.startPrank(address(settlement));

        vm.expectRevert(ISilo.InvalidSellToken.selector);
        silo.commit(bytes32(uint256(1)), OZIERC20(address(0)), 1);

        vm.expectRevert(ISilo.InvalidSellToken.selector);
        silo.commit(bytes32(uint256(1)), OZIERC20(address(resource)), 1);

        vm.stopPrank();
    }

    function testCommitRejectsZeroSellAmount() public {
        vm.prank(address(settlement));
        vm.expectRevert(ISilo.EmptyBalance.selector);
        silo.commit(bytes32(uint256(1)), OZIERC20(address(collected)), 0);
    }

    function testSignatureRevertsWithoutCommitment() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);
        vm.expectRevert(ISilo.InvalidCommitment.selector);
        silo.isValidSignature(digest, abi.encode(order));
    }

    function testSignatureRejectsOrderThatDoesNotMatchCommittedHash() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 differentDigest = keccak256("different order");

        vm.expectRevert(ISilo.InvalidOrderHash.selector);
        settlement.commitAndValidate(
            silo, differentDigest, OZIERC20(address(collected)), order.sellAmount, abi.encode(order)
        );
    }

    function testVerifyRequiresFullBalance() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(99, 20);
        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 99, 100));
        silo.verify(order);
    }

    function testVerifyRejectsWrongReceiver() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.receiver = makeAddr("thief");
        vm.expectRevert(ISilo.InvalidReceiver.selector);
        silo.verify(order);
    }

    function testVerifyRejectsWrongBuyToken() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.buyToken = IERC20(address(collected));
        vm.expectRevert(ISilo.InvalidBuyToken.selector);
        silo.verify(order);
    }

    function testVerifyRejectsEmptyBalance() public {
        GPv2Order.Data memory order = validOrder(100, 20);
        vm.expectRevert(ISilo.EmptyBalance.selector);
        silo.verify(order);
    }

    function testVerifyRejectsResourceAsSellToken() public {
        resource.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.sellToken = IERC20(address(resource));
        vm.expectRevert(ISilo.InvalidSellToken.selector);
        silo.verify(order);
    }

    function testVerifyRejectsOrderThatLivesTooLong() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.validTo = uint32(block.timestamp + silo.MAX_ORDER_DURATION() + 1);
        vm.expectRevert(ISilo.InvalidValidity.selector);
        silo.verify(order);
    }

    function testVerifyRejectsExpiredOrder() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.validTo = uint32(block.timestamp - 1);
        vm.expectRevert(ISilo.InvalidValidity.selector);
        silo.verify(order);
    }

    function testVerifyRejectsPartialFill() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.partiallyFillable = true;
        vm.expectRevert(ISilo.OrderIsPartiallyFillable.selector);
        silo.verify(order);
    }

    function testVerifyRejectsWrongAppData() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.appData = keccak256("wrong app data");
        vm.expectRevert(ISilo.InvalidAppData.selector);
        silo.verify(order);
    }

    function testVerifyRejectsFee() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.feeAmount = 1;
        vm.expectRevert(ISilo.InvalidFee.selector);
        silo.verify(order);
    }

    function testVerifyRejectsBuyOrder() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.kind = GPv2Order.KIND_BUY;
        vm.expectRevert(ISilo.InvalidKind.selector);
        silo.verify(order);
    }

    function testVerifyRejectsExternalSellBalance() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.sellTokenBalance = GPv2Order.BALANCE_EXTERNAL;
        vm.expectRevert(ISilo.InvalidBalanceType.selector);
        silo.verify(order);
    }

    function testVerifyRejectsInternalBuyBalance() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.buyTokenBalance = GPv2Order.BALANCE_INTERNAL;
        vm.expectRevert(ISilo.InvalidBalanceType.selector);
        silo.verify(order);
    }

    function testVerifyRejectsBuyAmountBelowMinimum() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, MINIMUM_BUY_AMOUNT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, MINIMUM_BUY_AMOUNT - 1, MINIMUM_BUY_AMOUNT)
        );
        silo.verify(order);
    }

    function testOwnerCanSetMinimumBuyAmount() public {
        uint256 newMinimum = 25 ether;

        vm.expectEmit(false, false, false, true, address(silo));
        emit ISilo.MinimumBuyAmountSet(MINIMUM_BUY_AMOUNT, newMinimum);
        vm.prank(owner);
        silo.setMinimumBuyAmount(newMinimum);

        assertEq(silo.minimumBuyAmount(), newMinimum);
    }

    function testUpdatedMinimumAppliesToExistingInventory() public {
        uint256 newMinimum = 25 ether;
        collected.mint(address(silo), 100 ether);

        vm.prank(owner);
        silo.setMinimumBuyAmount(newMinimum);

        GPv2Order.Data memory order = validOrder(100 ether, newMinimum - 1);
        vm.expectRevert(abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, newMinimum - 1, newMinimum));
        silo.verify(order);
    }

    function testOwnershipTransferRequiresAcceptance() public {
        address nextOwner = makeAddr("nextOwner");

        vm.prank(owner);
        silo.transferOwnership(nextOwner);

        assertEq(silo.owner(), owner);
        assertEq(silo.pendingOwner(), nextOwner);

        vm.prank(nextOwner);
        silo.acceptOwnership();

        assertEq(silo.owner(), nextOwner);
        assertEq(silo.pendingOwner(), address(0));
    }

    function testSetMinimumBuyAmountRejectsUnauthorizedCaller() public {
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        silo.setMinimumBuyAmount(25 ether);
    }

    function testSetMinimumBuyAmountRejectsZero() public {
        vm.expectRevert(ISilo.InvalidMinimumBuyAmount.selector);
        vm.prank(owner);
        silo.setMinimumBuyAmount(0);
    }

    function testConstructorRejectsZeroMinimumBuyAmount() public {
        vm.expectRevert(ISilo.InvalidMinimumBuyAmount.selector);
        new Silo(settlement, IERC20(address(resource)), recipient, 0, APP_DATA, owner);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(ISettlement(address(0)), IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, APP_DATA, owner);

        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(settlement, IERC20(address(0)), recipient, MINIMUM_BUY_AMOUNT, APP_DATA, owner);

        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(settlement, IERC20(address(resource)), address(0), MINIMUM_BUY_AMOUNT, APP_DATA, owner);
    }

    function testConstructorRejectsZeroVaultRelayer() public {
        MockSettlement invalidSettlement = new MockSettlement(DOMAIN_SEPARATOR, address(0));
        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(invalidSettlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, APP_DATA, owner);
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Silo(settlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, APP_DATA, address(0));
    }

    function testFuzzVerifyAcceptsCanonicalOrder(uint128 sellAmount, uint128 buyAmount, uint16 validFor) public {
        vm.assume(sellAmount > 0);
        buyAmount = uint128(bound(buyAmount, MINIMUM_BUY_AMOUNT, type(uint128).max));
        validFor = uint16(bound(validFor, 0, silo.MAX_ORDER_DURATION()));
        collected.mint(address(silo), sellAmount);
        GPv2Order.Data memory order = validOrder(sellAmount, buyAmount);
        order.validTo = uint32(block.timestamp + validFor);
        silo.verify(order);
    }

    function testSdkHashVectorMatchesSolidity() public pure {
        GPv2Order.Data memory order = GPv2Order.Data({
            sellToken: IERC20(0x2222222222222222222222222222222222222222),
            buyToken: IERC20(0x3333333333333333333333333333333333333333),
            receiver: 0x4444444444444444444444444444444444444444,
            sellAmount: 100,
            buyAmount: 25,
            validTo: 1_900_000_000,
            appData: 0x5555555555555555555555555555555555555555555555555555555555555555,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        bytes32 sdkVector = 0x2743026369fc008bfc1b759b30bdc428f1516a769e23d728e3757d97bcd4e70d;
        bytes32 domain = 0x6666666666666666666666666666666666666666666666666666666666666666;
        assertEq(order.hash(domain), sdkVector);
    }

    function validOrder(uint256 sellAmount, uint256 buyAmount) internal view returns (GPv2Order.Data memory) {
        return validOrder(address(collected), sellAmount, buyAmount);
    }

    function validOrder(address sellToken, uint256 sellAmount, uint256 buyAmount)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(address(resource)),
            receiver: recipient,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: uint32(block.timestamp + 5 minutes),
            appData: APP_DATA,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
