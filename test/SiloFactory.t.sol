// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { Silo } from "../src/Silo.sol";
import { SiloFactory } from "../src/SiloFactory.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import { ISilo } from "../src/interfaces/ISilo.sol";
import { ISiloFactory } from "../src/interfaces/ISiloFactory.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";

contract SiloFactoryTest is Test {
    uint256 internal constant MINIMUM_BUY_AMOUNT = 10 ether;

    MockSettlement internal settlement;
    MockERC20 internal resource;
    SiloFactory internal factory;

    function setUp() public {
        settlement = new MockSettlement(keccak256("domain"), makeAddr("relayer"));
        resource = new MockERC20("Resource", "RSC");
        factory = new SiloFactory(settlement);
    }

    function testCreatesAtPredictedAddress() public {
        address creator = makeAddr("creator");
        address recipient = makeAddr("recipient");
        bytes32 appData = keccak256("appData");
        bytes32 userSalt = keccak256("userSalt");
        IERC20 token = IERC20(address(resource));
        address predicted =
            factory.predictSiloAddress(creator, token, recipient, 20 ether, MINIMUM_BUY_AMOUNT, 300, appData, userSalt);
        vm.expectEmit(true, true, true, true, address(factory));
        emit ISiloFactory.SiloCreated(
            predicted, creator, address(token), recipient, 20 ether, MINIMUM_BUY_AMOUNT, 300, appData, userSalt
        );
        vm.prank(creator);
        ISilo silo = factory.createSilo(token, recipient, 20 ether, MINIMUM_BUY_AMOUNT, 300, appData, userSalt);

        assertEq(address(silo), predicted);
        assertEq(Silo(address(silo)).owner(), creator);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
        assertEq(silo.initialBuyAmount(), 20 ether);
        assertEq(silo.minimumBuyAmount(), MINIMUM_BUY_AMOUNT);
        assertEq(silo.auctionDuration(), 300);
    }

    function testIgnoresAuctionDurationForFlatFloor() public {
        IERC20 token = IERC20(address(resource));
        address recipient = makeAddr("recipient");
        bytes32 appData = keccak256("appData");
        bytes32 userSalt = keccak256("userSalt");
        address predicted =
            factory.predictSiloAddress(address(this), token, recipient, 10 ether, 10 ether, 0, appData, userSalt);
        assertEq(
            factory.predictSiloAddress(address(this), token, recipient, 10 ether, 10 ether, 300, appData, userSalt),
            predicted
        );

        vm.expectEmit(true, true, true, true, address(factory));
        emit ISiloFactory.SiloCreated(
            predicted, address(this), address(token), recipient, 10 ether, 10 ether, 0, appData, userSalt
        );
        ISilo silo = factory.createSilo(token, recipient, 10 ether, 10 ether, 300, appData, userSalt);
        assertEq(address(silo), predicted);
        assertEq(silo.auctionDuration(), 0);
    }

    function testSaltNamespacesCreators() public view {
        bytes32 userSalt = keccak256("same");
        assertNotEq(factory.salt(address(1), userSalt), factory.salt(address(2), userSalt));
    }

    function testConstructorRejectsZeroSettlement() public {
        vm.expectRevert(ISiloFactory.ZeroAddress.selector);
        new SiloFactory(ISettlement(address(0)));
    }
}
