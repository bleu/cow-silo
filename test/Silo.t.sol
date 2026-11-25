// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { IHooksTrampoline } from "../src/interfaces/IHooksTrampoline.sol";
import { MockHooksTrampoline } from "./mocks/MockHooksTrampoline.sol";
import { Silo } from "../src/Silo.sol";
import { ApprovalFundingAdapter } from "../src/ApprovalFundingAdapter.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import { ISilo } from "../src/interfaces/ISilo.sol";
import { IFundingAdapter } from "../src/interfaces/IFundingAdapter.sol";
import { MockERC20, BalanceChangingApprovalERC20 } from "./mocks/MockERC20.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";
import {
    RevertingFundingAdapter,
    ReentrantFundingAdapter,
    GasBurningFundingAdapter,
    LargeReturnDataFundingAdapter,
    TransferThenRevertFundingAdapter
} from "./mocks/MockFundingAdapter.sol";

contract SiloTest is Test {
    using GPv2Order for GPv2Order.Data;
    using stdStorage for StdStorage;

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
    MockHooksTrampoline internal trampoline;

    function setUp() public {
        settlement = new MockSettlement(DOMAIN_SEPARATOR, vaultRelayer);
        trampoline = settlement.hooksTrampoline();
        resource = new MockERC20("Resource", "RSC");
        collected = new MockERC20("Collected", "FEE");
        collectedTwo = new MockERC20("Collected Two", "FEE2");
        silo = new Silo(settlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, owner);
        vm.warp(1_800_000_000);
    }

    function testConstructorSetsPermanentRules() public view {
        assertEq(address(silo.settlement()), address(settlement));
        assertEq(silo.vaultRelayer(), vaultRelayer);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
        assertEq(silo.minimumBuyAmount(), MINIMUM_BUY_AMOUNT);
        assertEq(silo.domainSeparator(), DOMAIN_SEPARATOR);
        assertEq(silo.owner(), owner);
    }

    function testHookGasLimitDefaultsTo500000() public view {
        assertEq(silo.hookGasLimit(), 500_000);
        assertEq(silo.FUNDING_GAS_LIMIT(), 200_000);
    }

    function testOwnerCanSetHookGasLimit() public {
        vm.expectEmit(false, false, false, true, address(silo));
        emit ISilo.HookGasLimitSet(500_000, 600_000);
        vm.prank(owner);
        silo.setHookGasLimit(600_000);
        assertEq(silo.hookGasLimit(), 600_000);
        assertEq(silo.FUNDING_GAS_LIMIT(), 200_000);

        vm.expectEmit(false, false, false, true, address(silo));
        emit ISilo.HookGasLimitSet(600_000, 1);
        vm.prank(owner);
        silo.setHookGasLimit(1);
        assertEq(silo.hookGasLimit(), 1);
    }

    function testFuzzOwnerCanSetAnyNonzeroHookGasLimit(uint256 newGasLimit) public {
        newGasLimit = bound(newGasLimit, 1, type(uint256).max);
        vm.prank(owner);
        silo.setHookGasLimit(newGasLimit);
        assertEq(silo.hookGasLimit(), newGasLimit);
    }

    function testSetHookGasLimitRejectsUnauthorizedCaller() public {
        address caller = makeAddr("caller");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        silo.setHookGasLimit(600_000);
        assertEq(silo.hookGasLimit(), 500_000);
    }

    function testSetHookGasLimitRejectsZero() public {
        vm.expectRevert(ISilo.InvalidHookGasLimit.selector);
        vm.prank(owner);
        silo.setHookGasLimit(0);
        assertEq(silo.hookGasLimit(), 500_000);
    }

    function testHookGasLimitChangeRejectsOldDocumentAndRestoringLimitAcceptsIt() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory oldOrder = validOrder(100, 20);
        bytes32 oldDigest = oldOrder.hash(DOMAIN_SEPARATOR);
        silo.prepare(OZIERC20(address(collected)));
        assertEq(silo.isValidSignature(oldDigest, abi.encode(oldOrder)), IERC1271.isValidSignature.selector);

        vm.prank(owner);
        silo.setHookGasLimit(600_000);
        assertNotEq(silo.appData(OZIERC20(address(collected))), oldOrder.appData);
        vm.expectRevert(ISilo.InvalidAppData.selector);
        silo.isValidSignature(oldDigest, abi.encode(oldOrder));

        GPv2Order.Data memory newOrder = validOrder(100, 20);
        (, bytes4 result) = settlement.prepareAndValidate(
            silo, newOrder.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(newOrder)
        );
        assertEq(result, IERC1271.isValidSignature.selector);

        vm.prank(owner);
        silo.setHookGasLimit(500_000);
        assertEq(silo.appData(OZIERC20(address(collected))), oldOrder.appData);
        assertEq(silo.isValidSignature(oldDigest, abi.encode(oldOrder)), IERC1271.isValidSignature.selector);
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

    function testPrepareFundsEmptySiloAndValidatesOrder() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 100);
        vm.prank(source);
        collected.approve(address(adapter), 100);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(100, 20);

        (bool observedPreparation, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertTrue(observedPreparation);
        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 0);
        assertEq(collected.balanceOf(address(silo)), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
    }

    function testPrepareSellsCombinedInventory() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(address(silo), 40);
        collected.mint(source, 60);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(address(silo)), 100);
        assertEq(collected.balanceOf(source), 0);
    }

    function testPrepareIgnoresFundingRevertForPrefundedOrder() public {
        RevertingFundingAdapter adapter = new RevertingFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testPrepareSurvivesAdapterExhaustingForwardedGas() public {
        GasBurningFundingAdapter adapter = new GasBurningFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.prepareAndValidate{ gas: 800_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testPrepareIgnoresLargeAdapterReturnData() public {
        LargeReturnDataFundingAdapter adapter = new LargeReturnDataFundingAdapter(false);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.prepareAndValidate{ gas: 800_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testPrepareIgnoresLargeAdapterRevertData() public {
        LargeReturnDataFundingAdapter adapter = new LargeReturnDataFundingAdapter(true);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        (, bytes4 result) = settlement.prepareAndValidate{ gas: 800_000 }(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testPrepareBalanceMismatchRollsBackFunding() public {
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

        vm.expectRevert(ISilo.InvalidPreparation.selector);
        settlement.prepareAndValidate(silo, digest, OZIERC20(address(collected)), 99, abi.encode(order));

        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
        assertEq(collected.allowance(source, address(adapter)), 60);
        assertEq(collected.allowance(address(silo), vaultRelayer), 0);
        assertFalse(silo.preparedBalance(OZIERC20(address(collected))) != 0);
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
        settlement.prepareAndValidate(silo, digest, OZIERC20(address(collected)), 100, abi.encode(order));

        assertEq(collected.balanceOf(source), 100);
        assertEq(collected.balanceOf(address(silo)), 0);
        assertEq(collected.allowance(source, address(adapter)), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), 0);
        assertFalse(silo.preparedBalance(OZIERC20(address(collected))) != 0);
    }

    function testPrepareUsesReplacementAdapter() public {
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

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 80, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(oldSource), 60);
        assertEq(collected.balanceOf(newSource), 0);
        assertEq(collected.balanceOf(address(silo)), 80);
    }

    function testPrepareSkipsDisabledAdapter() public {
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

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
        assertEq(address(silo.fundingAdapter()), address(0));
    }

    function testAdapterRevertRollsBackItsTransferButNotPreparation() public {
        address source = makeAddr("source");
        TransferThenRevertFundingAdapter adapter = new TransferThenRevertFundingAdapter(source);
        collected.mint(source, 60);
        collected.mint(address(silo), 40);
        vm.prank(source);
        collected.approve(address(adapter), 60);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(40, 20);

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.allowance(source, address(adapter)), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
    }

    function testPrepareRejectsInsufficientBalanceAfterFundingFailure() public {
        RevertingFundingAdapter adapter = new RevertingFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 40);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        vm.expectRevert(ISilo.InvalidPreparation.selector);
        settlement.prepareAndValidate(silo, digest, OZIERC20(address(collected)), 100, abi.encode(order));

        assertFalse(silo.preparedBalance(OZIERC20(address(collected))) != 0);
    }

    function testFuzzPrepareCombinesExistingAndApprovedInventory(uint128 existing, uint128 approved) public {
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

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), amount, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(address(silo)), amount);
        assertEq(collected.balanceOf(source), approved);
        assertEq(collected.allowance(source, address(adapter)), 0);
    }

    function testPrepareValidatesPrefundedOrderWithoutSourceAllowance() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 60);
        collected.mint(address(silo), 40);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        GPv2Order.Data memory order = validOrder(40, 20);

        (, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 40, abi.encode(order)
        );

        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(collected.balanceOf(source), 60);
        assertEq(collected.balanceOf(address(silo)), 40);
    }

    function testPrepareApprovesRelayerAndMakesSignatureValid() public {
        uint256 amount = 100 ether;
        collected.mint(address(silo), amount);
        GPv2Order.Data memory order = validOrder(amount, 9 ether);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        (bool observedPreparation, bytes4 result) =
            settlement.prepareAndValidate(silo, digest, OZIERC20(address(collected)), amount, abi.encode(order));

        assertTrue(observedPreparation);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testPreparationStartsEmpty() public view {
        assertFalse(silo.preparedBalance(OZIERC20(address(collected))) != 0);
    }

    function testPrepareSupportsMultipleOrdersInOneSettlement() public {
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

        (bool[2] memory observedPreparations, bytes4[2] memory results) =
            settlement.prepareAndValidateTwo(silo, digests, sellTokens, sellAmounts, signatures);

        assertTrue(observedPreparations[0]);
        assertTrue(observedPreparations[1]);
        assertEq(results[0], IERC1271.isValidSignature.selector);
        assertEq(results[1], IERC1271.isValidSignature.selector);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(collectedTwo.allowance(address(silo), vaultRelayer), type(uint256).max);
    }

    function testUnrelatedAccountCanPrepareAndValidateOrder() public {
        address caller = makeAddr("caller");
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);

        vm.expectEmit(true, false, false, true, address(silo));
        emit ISilo.TokenPrepared(address(collected), 100);
        vm.prank(caller);
        silo.prepare(OZIERC20(address(collected)));

        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(collected.balanceOf(caller), 0);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testUnrelatedAccountCanTriggerFundingOnlyIntoFixedSilo() public {
        address source = makeAddr("source");
        address caller = makeAddr("caller");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        collected.mint(source, 150);
        vm.prank(source);
        collected.approve(address(adapter), 100);
        vm.prank(owner);
        silo.setFundingAdapter(adapter);

        vm.prank(caller);
        silo.prepare(OZIERC20(address(collected)));

        assertEq(collected.balanceOf(source), 50);
        assertEq(collected.allowance(source, address(adapter)), 0);
        assertEq(collected.balanceOf(address(silo)), 100);
        assertEq(collected.balanceOf(caller), 0);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testPrepareRejectsInvalidSellToken() public {
        vm.startPrank(makeAddr("caller"));

        vm.expectRevert(ISilo.InvalidSellToken.selector);
        silo.prepare(OZIERC20(address(0)));

        vm.expectRevert(ISilo.InvalidSellToken.selector);
        silo.prepare(OZIERC20(address(resource)));

        vm.stopPrank();
    }

    function testPrepareRejectsZeroBalance() public {
        vm.prank(makeAddr("caller"));
        vm.expectRevert(ISilo.EmptyBalance.selector);
        silo.prepare(OZIERC20(address(collected)));
    }

    function testSignatureRevertsWithoutPreparation() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(digest, abi.encode(order));
    }

    function testSignatureRejectsWrongOrderHash() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 differentDigest = keccak256("different order");

        vm.expectRevert(ISilo.InvalidOrderHash.selector);
        settlement.prepareAndValidate(
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
        new Silo(settlement, IERC20(address(resource)), recipient, 0, owner);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(ISettlement(address(0)), IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, owner);

        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(settlement, IERC20(address(0)), recipient, MINIMUM_BUY_AMOUNT, owner);

        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(settlement, IERC20(address(resource)), address(0), MINIMUM_BUY_AMOUNT, owner);
    }

    function testConstructorRejectsZeroVaultRelayer() public {
        MockSettlement invalidSettlement = new MockSettlement(DOMAIN_SEPARATOR, address(0));
        vm.expectRevert(ISilo.ZeroAddress.selector);
        new Silo(invalidSettlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, owner);
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Silo(settlement, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, address(0));
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

    function testSnapshotIncludesApprovalBalanceChange() public {
        BalanceChangingApprovalERC20 token = new BalanceChangingApprovalERC20();
        token.mint(address(silo), 100);
        settlement.prepare(silo, OZIERC20(address(token)), 500_000);
        assertEq(silo.preparedBalance(OZIERC20(address(token))), 101);
        GPv2Order.Data memory order = validOrder(address(token), 101, 20);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testFundingFailureOfEmptySiloLeavesNoPreparation() public {
        RevertingFundingAdapter adapter = new RevertingFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 0);
        GPv2Order.Data memory order = validOrder(100, 20);
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
        collected.mint(address(silo), 100);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testPrepareAcceptsDirectSettlementCaller() public {
        collected.mint(address(silo), 100);
        vm.prank(address(settlement));
        silo.prepare(OZIERC20(address(collected)));

        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        GPv2Order.Data memory order = validOrder(100, 20);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testTrampolineRejectsNonSettlementCaller() public {
        IHooksTrampoline.Hook[] memory hooks = new IHooksTrampoline.Hook[](0);
        vm.expectRevert(MockHooksTrampoline.NotASettlement.selector);
        trampoline.execute(hooks);
    }

    function testFundingCallbackCannotReplaceFirstSuccessfulSnapshot() public {
        ReentrantFundingAdapter adapter = new ReentrantFundingAdapter();
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(address(silo), 100);
        collected.mint(address(adapter), 1);

        vm.prank(makeAddr("caller"));
        silo.prepare(OZIERC20(address(collected)));

        assertEq(collected.balanceOf(address(silo)), 101);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 100, 101));
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
        order.sellAmount = 101;
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
    }

    function testRepeatedPreparationKeepsFirstSnapshotAndSkipsFunding() public {
        address source = makeAddr("source");
        ApprovalFundingAdapter adapter = new ApprovalFundingAdapter(source, address(silo));
        vm.prank(owner);
        silo.setFundingAdapter(adapter);
        collected.mint(source, 100);
        vm.prank(source);
        collected.approve(address(adapter), 100);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
        collected.mint(source, 50);
        vm.prank(source);
        collected.approve(address(adapter), 50);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        assertEq(collected.balanceOf(source), 50);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
    }

    function testPreparationAllowsDifferentValidOrderForSameTokenAndAmount() public {
        collected.mint(address(silo), 100);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        GPv2Order.Data memory order = validOrder(100, 20);
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
        order.buyAmount = 30;
        assertEq(
            silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order)), IERC1271.isValidSignature.selector
        );
    }

    function testChangedLiveBalanceInvalidatesPreparedOrder() public {
        collected.mint(address(silo), 100);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        collected.mint(address(silo), 1);
        GPv2Order.Data memory order = validOrder(100, 20);
        vm.expectRevert(abi.encodeWithSelector(ISilo.BalanceChanged.selector, 100, 101));
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
        order.sellAmount = 101;
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 100);
    }

    function testPreparationDoesNotAuthorizeAnotherToken() public {
        collected.mint(address(silo), 100);
        collectedTwo.mint(address(silo), 100);
        settlement.prepare(silo, OZIERC20(address(collected)), 500_000);
        GPv2Order.Data memory order = validOrder(address(collectedTwo), 100, 20);
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
    }

    function testHookOutOfGasLeavesTokenUnprepared() public {
        collected.mint(address(silo), 100);
        vm.prank(owner);
        silo.setHookGasLimit(1_000);
        settlement.prepare(silo, OZIERC20(address(collected)), silo.hookGasLimit());
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 0);
        assertEq(collected.allowance(address(silo), vaultRelayer), 0);
        GPv2Order.Data memory order = validOrder(100, 20);
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
    }

    function testTrampolineRejectsInsufficientOuterGasBudget() public {
        collected.mint(address(silo), 100);
        (bool success,) = address(settlement).call{ gas: 400_000 }(
            abi.encodeCall(MockSettlement.prepare, (silo, OZIERC20(address(collected)), 500_000))
        );
        assertFalse(success);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 0);
    }

    // Run with TEST_ISOLATED=true forge test --isolate --match-test testPreparationExpiresAfterTransaction.
    function testPreparationExpiresAfterTransaction() public {
        vm.skip(!vm.envOr("TEST_ISOLATED", false));
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        (bool prepared, bytes4 result) = settlement.prepareAndValidate(
            silo, order.hash(DOMAIN_SEPARATOR), OZIERC20(address(collected)), 100, abi.encode(order)
        );
        assertTrue(prepared);
        assertEq(result, IERC1271.isValidSignature.selector);
        assertEq(silo.preparedBalance(OZIERC20(address(collected))), 0);
        vm.expectRevert(ISilo.InvalidPreparation.selector);
        silo.isValidSignature(order.hash(DOMAIN_SEPARATOR), abi.encode(order));
    }

    function testCanonicalAppDataSharedVectors() public {
        address target = address(0xab);
        vm.etch(target, address(silo).code);
        stdstore.target(target).sig("owner()").checked_write(owner);
        vm.prank(owner);
        Silo(target).setHookGasLimit(500_000);
        string memory document =
            '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x00000000000000000000000000000000000000ab","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd","gasLimit":"500000"}]}}}';
        bytes32 expected = 0xee2957f4feeb0e935ca682ff1afe936e7bdf5a06392ad586173f4116a9fcea76;
        assertEq(keccak256(bytes(document)), expected);
        assertEq(
            abi.encodeCall(ISilo.prepare, (OZIERC20(address(0xcd)))),
            hex"babed18a00000000000000000000000000000000000000000000000000000000000000cd"
        );
        assertEq(Silo(target).appData(OZIERC20(address(0xcd))), expected);
        assertEq(
            Silo(target).appData(OZIERC20(address(0xef))),
            0x8ba2f9a5d77f6d1be2766857a0f1e2bfacb71269901694d10df84815e25778c2
        );
        document =
            '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x00000000000000000000000000000000000000ab","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd","gasLimit":"600000"}]}}}';
        expected = 0xbc735adaef4c18f438c2d6baeefc621df188217f2bb6b606c9a2e4003ecd9436;
        vm.prank(owner);
        Silo(target).setHookGasLimit(600_000);
        assertEq(keccak256(bytes(document)), expected);
        assertEq(Silo(target).appData(OZIERC20(address(0xcd))), expected);

        document =
            '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x00000000000000000000000000000000000000ab","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd","gasLimit":"115792089237316195423570985008687907853269984665640564039457584007913129639935"}]}}}';
        expected = 0x16c15ab419985a293ad2615b457d711f0ec01fbeaae6ddbac7dce3b15633feb5;
        vm.prank(owner);
        Silo(target).setHookGasLimit(type(uint256).max);
        assertEq(Silo(target).hookGasLimit(), type(uint256).max);
        assertEq(keccak256(bytes(document)), expected);
        assertEq(Silo(target).appData(OZIERC20(address(0xcd))), expected);

        target = address(0x12);
        vm.etch(target, address(silo).code);
        stdstore.target(target).sig("owner()").checked_write(owner);
        vm.prank(owner);
        Silo(target).setHookGasLimit(500_000);
        assertEq(
            Silo(target).appData(OZIERC20(address(0xcd))),
            0x7f64d7a41a78a56583d060d25b6c7d3bffa38035ce56c83bc69dd074c002de22
        );
    }

    function testRejectsChangedAppDataDocumentBytes() public {
        collected.mint(address(silo), 100);
        string memory target = vm.toLowercase(vm.toString(address(silo)));
        string memory callData =
            vm.toLowercase(vm.toString(abi.encodeCall(ISilo.prepare, (OZIERC20(address(collected))))));
        string memory prefix = string.concat(
            '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"', target, '","callData":"', callData
        );
        string memory canonical = string.concat(prefix, '","gasLimit":"500000"}]}}}');
        assertEq(silo.appData(OZIERC20(address(collected))), keccak256(bytes(canonical)));
        bytes32[7] memory changed = [
            keccak256(
                bytes(
                    string.concat(
                        prefix,
                        '","gasLimit":"500000"},{"target":"',
                        target,
                        '","callData":"',
                        callData,
                        '","gasLimit":"500000"}]}}}'
                    )
                )
            ),
            keccak256(bytes(string.concat(prefix, '","gasLimit":"499999"}]}}}'))),
            keccak256(bytes(string.concat(prefix, '","gasLimit":"500000"}],"post":[]}}}'))),
            keccak256(bytes(string.concat(canonical, " "))),
            keccak256(
                bytes(
                    string.concat(
                        '{"version":"1.3.0","metadata":{"extra":true,"hooks":{"pre":[{"target":"',
                        target,
                        '","callData":"',
                        callData,
                        '","gasLimit":"500000"}]}}}'
                    )
                )
            ),
            keccak256(
                bytes(
                    string.concat(
                        '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"',
                        target,
                        '","callData":"0xbabed18a0000000000000000000000000000000000000000000000000000000000000000","gasLimit":"500000"}]}}}'
                    )
                )
            ),
            keccak256(
                bytes(
                    string.concat(
                        '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x0000000000000000000000000000000000000001","callData":"',
                        callData,
                        '","gasLimit":"500000"}]}}}'
                    )
                )
            )
        ];
        GPv2Order.Data memory order = validOrder(100, 20);
        for (uint256 i; i < changed.length; ++i) {
            order.appData = changed[i];
            vm.expectRevert(ISilo.InvalidAppData.selector);
            silo.verify(order);
        }
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
            appData: silo.appData(OZIERC20(sellToken)),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
