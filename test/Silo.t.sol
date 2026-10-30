// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { Silo } from "../src/Silo.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";

contract SiloTest is Test {
    using GPv2Order for GPv2Order.Data;

    bytes32 internal constant APP_DATA = keccak256("cow-silo:test");
    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow-silo:domain");

    address internal vaultRelayer = makeAddr("vaultRelayer");
    address internal recipient = makeAddr("recipient");

    MockSettlement internal settlement;
    MockERC20 internal resource;
    MockERC20 internal collected;
    Silo internal silo;

    function setUp() public {
        settlement = new MockSettlement(DOMAIN_SEPARATOR, vaultRelayer);
        resource = new MockERC20("Resource", "RSC");
        collected = new MockERC20("Collected", "FEE");
        silo = new Silo(settlement, IERC20(address(resource)), recipient, APP_DATA);
        vm.warp(1_800_000_000);
    }

    function testConstructorSetsPermanentRules() public view {
        assertEq(address(silo.settlement()), address(settlement));
        assertEq(silo.vaultRelayer(), vaultRelayer);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
        assertEq(silo.appData(), APP_DATA);
        assertEq(silo.domainSeparator(), DOMAIN_SEPARATOR);
    }

    function testCommitApprovesRelayerAndMakesSignatureValid() public {
        uint256 amount = 100 ether;
        collected.mint(address(silo), amount);
        GPv2Order.Data memory order = validOrder(amount, 9 ether);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);

        (bytes32 observedCommitment, bytes4 result) =
            settlement.commitAndValidate(silo, digest, OZIERC20(address(collected)), amount, abi.encode(order));

        assertEq(observedCommitment, digest);
        assertEq(collected.allowance(address(silo), vaultRelayer), type(uint256).max);
        assertEq(result, IERC1271.isValidSignature.selector);
    }

    function testCommitRevertsOutsideSettlement() public {
        collected.mint(address(silo), 1);
        vm.expectRevert(Silo.CommitOutsideSettlement.selector);
        silo.commit(bytes32(uint256(1)), OZIERC20(address(collected)), 1);
    }

    function testCommitRevertsWhenBalanceChanged() public {
        collected.mint(address(silo), 10);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(Silo.BalanceChanged.selector, 11, 10));
        silo.commit(bytes32(uint256(1)), OZIERC20(address(collected)), 11);
    }

    function testSignatureRevertsWithoutCommitment() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        bytes32 digest = order.hash(DOMAIN_SEPARATOR);
        vm.expectRevert(Silo.InvalidCommitment.selector);
        silo.isValidSignature(digest, abi.encode(order));
    }

    function testVerifyRequiresFullBalance() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(99, 20);
        vm.expectRevert(abi.encodeWithSelector(Silo.BalanceChanged.selector, 99, 100));
        silo.verify(order);
    }

    function testVerifyRejectsWrongReceiver() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.receiver = makeAddr("thief");
        vm.expectRevert(Silo.InvalidReceiver.selector);
        silo.verify(order);
    }

    function testVerifyRejectsResourceAsSellToken() public {
        resource.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.sellToken = IERC20(address(resource));
        vm.expectRevert(Silo.InvalidSellToken.selector);
        silo.verify(order);
    }

    function testVerifyRejectsOrderThatLivesTooLong() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.validTo = uint32(block.timestamp + silo.MAX_ORDER_DURATION() + 1);
        vm.expectRevert(Silo.InvalidValidity.selector);
        silo.verify(order);
    }

    function testVerifyRejectsPartialFill() public {
        collected.mint(address(silo), 100);
        GPv2Order.Data memory order = validOrder(100, 20);
        order.partiallyFillable = true;
        vm.expectRevert(Silo.OrderIsPartiallyFillable.selector);
        silo.verify(order);
    }

    function testFuzzVerifyAcceptsCanonicalOrder(uint128 sellAmount, uint128 buyAmount, uint16 validFor) public {
        vm.assume(sellAmount > 0 && buyAmount > 0);
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
        return GPv2Order.Data({
            sellToken: IERC20(address(collected)),
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
