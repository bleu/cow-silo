// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 as CoWIERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { Silo } from "../../src/Silo.sol";
import { ApprovalFundingAdapter } from "../../src/ApprovalFundingAdapter.sol";
import { ISilo } from "../../src/interfaces/ISilo.sol";
import { RevertingFundingAdapter } from "../../test/mocks/MockFundingAdapter.sol";
import { IMainnetSettlement, IWETH } from "./helpers/IMainnetSettlement.sol";

contract SiloSettlementTest is Test {
    using GPv2Order for GPv2Order.Data;

    uint256 internal constant FORK_BLOCK = 26_399_049;
    string internal constant PUBLIC_RPC = "https://eth.drpc.org";
    IMainnetSettlement internal constant SETTLEMENT = IMainnetSettlement(0x9008D19f58AAbD9eD0D60971565AA8510560ab41);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IWETH internal constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address internal constant SOLVER = 0x5ed864e8f37DCB4f79c5172A815D1B3a9147eaaB;
    address internal constant USDC_HOLDER = 0x55FE002aefF02F77364de339a1292923A15844B8;
    address internal constant AUTHENTICATOR = 0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE;
    address internal constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    uint256 internal constant SELL_AMOUNT = 1e6;
    uint256 internal constant BUY_AMOUNT = 5e14;
    bytes32 internal constant APP_DATA = keccak256("cow-silo:mainnet-fork");

    address internal treasury = makeAddr("treasury");
    address internal recipient = makeAddr("recipient");
    Silo internal silo;
    ApprovalFundingAdapter internal adapter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", PUBLIC_RPC), vm.envOr("MAINNET_FORK_BLOCK", FORK_BLOCK));
        assertEq(block.chainid, 1, "Ethereum mainnet required");
        assertGt(address(SETTLEMENT).code.length, 0, "Settlement code missing");
        assertGt(address(USDC).code.length, 0, "USDC code missing");
        assertGt(address(WETH).code.length, 0, "WETH code missing");
        assertEq(address(SETTLEMENT.authenticator()), AUTHENTICATOR);
        assertEq(SETTLEMENT.vaultRelayer(), VAULT_RELAYER);
        assertTrue(SETTLEMENT.authenticator().isSolver(SOLVER), "Fixture solver is not authorized");
        assertGe(USDC.balanceOf(USDC_HOLDER), 3 * SELL_AMOUNT, "Fixture holder needs USDC");

        silo = new Silo(SETTLEMENT, CoWIERC20(address(WETH)), recipient, BUY_AMOUNT, APP_DATA, address(this));
        adapter = new ApprovalFundingAdapter(treasury, address(silo));
        silo.setFundingAdapter(adapter);

        vm.prank(USDC_HOLDER);
        assertTrue(USDC.transfer(treasury, 3 * SELL_AMOUNT));
        vm.prank(treasury);
        assertTrue(USDC.approve(address(adapter), SELL_AMOUNT));

        vm.deal(SOLVER, 1 ether);
        vm.startPrank(SOLVER);
        WETH.deposit{ value: BUY_AMOUNT }();
        assertTrue(WETH.approve(address(SETTLEMENT), BUY_AMOUNT));
        vm.stopPrank();
    }

    function testExternalTreasuryFundsAndSettlesOrder() public {
        uint256 sourceBefore = USDC.balanceOf(treasury);
        uint256 solverUsdcBefore = USDC.balanceOf(SOLVER);
        uint256 solverWethBefore = WETH.balanceOf(SOLVER);
        uint256 recipientBefore = WETH.balanceOf(recipient);
        uint256 bufferUsdcBefore = USDC.balanceOf(address(SETTLEMENT));
        uint256 bufferWethBefore = WETH.balanceOf(address(SETTLEMENT));
        GPv2Order.Data memory order = _order(SELL_AMOUNT, BUY_AMOUNT);

        _settle(order);

        assertEq(USDC.balanceOf(treasury), sourceBefore - SELL_AMOUNT);
        assertEq(USDC.balanceOf(address(silo)), 0);
        assertEq(USDC.balanceOf(SOLVER), solverUsdcBefore + SELL_AMOUNT);
        assertEq(WETH.balanceOf(SOLVER), solverWethBefore - BUY_AMOUNT);
        assertEq(WETH.balanceOf(recipient), recipientBefore + BUY_AMOUNT);
        assertEq(USDC.balanceOf(address(SETTLEMENT)), bufferUsdcBefore);
        assertEq(WETH.balanceOf(address(SETTLEMENT)), bufferWethBefore);
        assertEq(SETTLEMENT.filledAmount(_uid(order)), SELL_AMOUNT);
    }

    function testExistingInventoryCombinesWithApprovedFunding() public {
        vm.prank(treasury);
        assertTrue(USDC.transfer(address(silo), SELL_AMOUNT));
        uint256 sourceBefore = USDC.balanceOf(treasury);
        uint256 solverBefore = USDC.balanceOf(SOLVER);
        uint256 bufferBefore = USDC.balanceOf(address(SETTLEMENT));
        uint256 recipientBefore = WETH.balanceOf(recipient);
        GPv2Order.Data memory order = _order(2 * SELL_AMOUNT, BUY_AMOUNT);

        _settle(order);

        assertEq(USDC.balanceOf(treasury), sourceBefore - SELL_AMOUNT);
        assertEq(USDC.balanceOf(treasury), SELL_AMOUNT);
        assertEq(USDC.allowance(treasury, address(adapter)), 0);
        assertEq(USDC.balanceOf(address(silo)), 0);
        assertEq(USDC.balanceOf(SOLVER), solverBefore + 2 * SELL_AMOUNT);
        assertEq(USDC.balanceOf(address(SETTLEMENT)), bufferBefore);
        assertEq(WETH.balanceOf(recipient), recipientBefore + BUY_AMOUNT);
        assertEq(SETTLEMENT.filledAmount(_uid(order)), 2 * SELL_AMOUNT);
    }

    function testSettlementBufferFundingConsumesOnlyApprovedBudget() public {
        adapter = new ApprovalFundingAdapter(address(SETTLEMENT), address(silo));
        silo.setFundingAdapter(adapter);
        uint256 bufferBefore = USDC.balanceOf(address(SETTLEMENT));
        assertGt(bufferBefore, SELL_AMOUNT);
        uint256 wethBufferBefore = WETH.balanceOf(address(SETTLEMENT));
        uint256 solverBefore = USDC.balanceOf(SOLVER);
        uint256 recipientBefore = WETH.balanceOf(recipient);
        uint256 treasuryBefore = USDC.balanceOf(treasury);

        CoWIERC20[] memory tokens = new CoWIERC20[](0);
        uint256[] memory prices = new uint256[](0);
        IMainnetSettlement.Trade[] memory trades = new IMainnetSettlement.Trade[](0);
        IMainnetSettlement.Interaction[][3] memory interactions;
        interactions[0] = new IMainnetSettlement.Interaction[](1);
        interactions[0][0] = IMainnetSettlement.Interaction({
            target: address(USDC), value: 0, callData: abi.encodeCall(IERC20.approve, (address(adapter), SELL_AMOUNT))
        });
        interactions[1] = new IMainnetSettlement.Interaction[](0);
        interactions[2] = new IMainnetSettlement.Interaction[](0);
        vm.prank(SOLVER);
        SETTLEMENT.settle(tokens, prices, trades, interactions);
        assertEq(USDC.allowance(address(SETTLEMENT), address(adapter)), SELL_AMOUNT);

        GPv2Order.Data memory order = _order(SELL_AMOUNT, BUY_AMOUNT);
        _settle(order);

        assertEq(USDC.balanceOf(address(SETTLEMENT)), bufferBefore - SELL_AMOUNT);
        assertEq(USDC.allowance(address(SETTLEMENT), address(adapter)), 0);
        assertEq(WETH.balanceOf(address(SETTLEMENT)), wethBufferBefore);
        assertEq(USDC.balanceOf(treasury), treasuryBefore);
        assertEq(USDC.balanceOf(address(silo)), 0);
        assertEq(USDC.balanceOf(SOLVER), solverBefore + SELL_AMOUNT);
        assertEq(WETH.balanceOf(recipient), recipientBefore + BUY_AMOUNT);
        assertEq(SETTLEMENT.filledAmount(_uid(order)), SELL_AMOUNT);
    }

    function testRevertingAdapterStillAllowsPrefundedTrade() public {
        silo.setFundingAdapter(new RevertingFundingAdapter());
        vm.prank(treasury);
        assertTrue(USDC.transfer(address(silo), SELL_AMOUNT));
        uint256 sourceBefore = USDC.balanceOf(treasury);
        uint256 solverBefore = USDC.balanceOf(SOLVER);
        uint256 bufferBefore = USDC.balanceOf(address(SETTLEMENT));
        uint256 recipientBefore = WETH.balanceOf(recipient);
        GPv2Order.Data memory order = _order(SELL_AMOUNT, BUY_AMOUNT);

        _settle(order);

        assertEq(USDC.balanceOf(treasury), sourceBefore);
        assertEq(USDC.balanceOf(address(silo)), 0);
        assertEq(USDC.balanceOf(SOLVER), solverBefore + SELL_AMOUNT);
        assertEq(USDC.balanceOf(address(SETTLEMENT)), bufferBefore);
        assertEq(WETH.balanceOf(recipient), recipientBefore + BUY_AMOUNT);
        assertEq(SETTLEMENT.filledAmount(_uid(order)), SELL_AMOUNT);
    }

    function testWrongFundedBalanceRollsBackFunding() public {
        GPv2Order.Data memory order = _order(SELL_AMOUNT + 1, BUY_AMOUNT);
        bytes memory stateBefore = _tradeState(order);

        _settle(order, abi.encodeWithSelector(ISilo.BalanceChanged.selector, SELL_AMOUNT + 1, SELL_AMOUNT));

        assertEq(_tradeState(order), stateBefore, "Failed commitment must roll back all trade state");
        assertFalse(silo.isCommitted(order.hash(silo.domainSeparator())));
    }

    function testBelowMinimumOrderRollsBackFunding() public {
        GPv2Order.Data memory order = _order(SELL_AMOUNT, BUY_AMOUNT - 1);
        bytes memory stateBefore = _tradeState(order);

        _settle(order, abi.encodeWithSelector(ISilo.BuyAmountBelowMinimum.selector, BUY_AMOUNT - 1, BUY_AMOUNT));

        assertEq(_tradeState(order), stateBefore, "Failed validation must roll back all trade state");
        assertFalse(silo.isCommitted(order.hash(silo.domainSeparator())));
    }

    function testLatePaymentFailureRollsBackEntireTrade() public {
        vm.prank(SOLVER);
        assertTrue(WETH.approve(address(SETTLEMENT), 0));
        GPv2Order.Data memory order = _order(SELL_AMOUNT, BUY_AMOUNT);
        bytes memory stateBefore = _tradeState(order);

        _settle(order, bytes(""));

        assertEq(_tradeState(order), stateBefore, "Failed payment must roll back all trade state");
        assertFalse(silo.isCommitted(order.hash(silo.domainSeparator())));
    }

    function _tradeState(GPv2Order.Data memory order) internal view returns (bytes memory) {
        bytes memory balances = abi.encode(
            USDC.balanceOf(treasury),
            USDC.balanceOf(address(silo)),
            USDC.balanceOf(SOLVER),
            USDC.balanceOf(address(SETTLEMENT)),
            WETH.balanceOf(SOLVER),
            WETH.balanceOf(recipient),
            WETH.balanceOf(address(SETTLEMENT))
        );
        return abi.encode(
            balances,
            USDC.allowance(treasury, address(adapter)),
            USDC.allowance(address(silo), VAULT_RELAYER),
            WETH.allowance(SOLVER, address(SETTLEMENT)),
            SETTLEMENT.filledAmount(_uid(order)),
            silo.isCommitted(order.hash(silo.domainSeparator()))
        );
    }

    function _order(uint256 sellAmount, uint256 buyAmount) internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: CoWIERC20(address(USDC)),
            buyToken: CoWIERC20(address(WETH)),
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

    function _settle(GPv2Order.Data memory order) internal {
        _settle(order, false, "");
    }

    function _settle(GPv2Order.Data memory order, bytes memory expectedRevert) internal {
        _settle(order, true, expectedRevert);
    }

    function _settle(GPv2Order.Data memory order, bool expectFailure, bytes memory expectedRevert) internal {
        CoWIERC20[] memory tokens = new CoWIERC20[](2);
        tokens[0] = order.sellToken;
        tokens[1] = order.buyToken;
        uint256[] memory prices = new uint256[](2);
        prices[0] = BUY_AMOUNT;
        prices[1] = order.sellAmount;
        IMainnetSettlement.Trade[] memory trades = new IMainnetSettlement.Trade[](1);
        trades[0] = IMainnetSettlement.Trade({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: 0x40,
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(address(silo), abi.encode(order))
        });
        IMainnetSettlement.Interaction[][3] memory interactions;
        interactions[0] = new IMainnetSettlement.Interaction[](1);
        interactions[0][0] = IMainnetSettlement.Interaction({
            target: address(silo),
            value: 0,
            callData: abi.encodeCall(ISilo.commit, (order.hash(silo.domainSeparator()), USDC, order.sellAmount))
        });
        interactions[1] = new IMainnetSettlement.Interaction[](2);
        interactions[1][0] = IMainnetSettlement.Interaction({
            target: address(USDC), value: 0, callData: abi.encodeCall(IERC20.transfer, (SOLVER, order.sellAmount))
        });
        interactions[1][1] = IMainnetSettlement.Interaction({
            target: address(WETH),
            value: 0,
            callData: abi.encodeCall(IERC20.transferFrom, (SOLVER, address(SETTLEMENT), BUY_AMOUNT))
        });
        interactions[2] = new IMainnetSettlement.Interaction[](0);

        if (expectFailure) vm.expectRevert(expectedRevert);
        vm.prank(SOLVER);
        SETTLEMENT.settle(tokens, prices, trades, interactions);
    }

    function _uid(GPv2Order.Data memory order) internal view returns (bytes memory) {
        return abi.encodePacked(order.hash(silo.domainSeparator()), address(silo), order.validTo);
    }
}
