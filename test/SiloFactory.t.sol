// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { Silo } from "../src/Silo.sol";
import { SiloFactory } from "../src/SiloFactory.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSettlement } from "./mocks/MockSettlement.sol";

contract SiloFactoryTest is Test {
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
        address predicted = factory.predictSiloAddress(creator, IERC20(address(resource)), recipient, appData, userSalt);

        vm.prank(creator);
        Silo silo = factory.createSilo(IERC20(address(resource)), recipient, appData, userSalt);

        assertEq(address(silo), predicted);
        assertEq(address(silo.resourceToken()), address(resource));
        assertEq(silo.resourceRecipient(), recipient);
    }

    function testSaltNamespacesCreators() public view {
        bytes32 userSalt = keccak256("same");
        assertNotEq(factory.salt(address(1), userSalt), factory.salt(address(2), userSalt));
    }
}
