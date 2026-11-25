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
        bytes32 userSalt = keccak256("userSalt");
        address predicted =
            factory.predictSiloAddress(creator, IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, userSalt);

        vm.prank(creator);
        ISilo deployedSilo = factory.createSilo(IERC20(address(resource)), recipient, MINIMUM_BUY_AMOUNT, userSalt);
        Silo silo = Silo(address(deployedSilo));

        assertEq(address(silo), predicted);
        assertEq(silo.owner(), creator);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
        assertEq(silo.minimumBuyAmount(), MINIMUM_BUY_AMOUNT);
    }

    function testSaltNamespacesCreators() public view {
        bytes32 userSalt = keccak256("same");
        assertNotEq(factory.salt(address(1), userSalt), factory.salt(address(2), userSalt));
    }

    function testConstructorRejectsZeroSettlement() public {
        vm.expectRevert(ISiloFactory.ZeroAddress.selector);
        new SiloFactory(ISettlement(address(0)));
    }

    function testCreatorNamespacesPredictedAddress() public view {
        address first = factory.predictSiloAddress(
            address(1), IERC20(address(resource)), address(3), MINIMUM_BUY_AMOUNT, bytes32(0)
        );
        address second = factory.predictSiloAddress(
            address(2), IERC20(address(resource)), address(3), MINIMUM_BUY_AMOUNT, bytes32(0)
        );
        assertNotEq(first, second);
    }
}
