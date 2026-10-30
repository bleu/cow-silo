// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { Silo } from "../src/Silo.sol";
import { SiloFactory } from "../src/SiloFactory.sol";
import { ISilo } from "../src/interfaces/ISilo.sol";

contract DeploySilo is Script {
    function run() external returns (Silo silo) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        SiloFactory factory = SiloFactory(vm.envAddress("SILO_FACTORY"));
        IERC20 resourceToken = IERC20(vm.envAddress("RESOURCE_TOKEN"));
        address resourceRecipient = vm.envAddress("RESOURCE_RECIPIENT");
        uint256 minimumBuyAmount = vm.envUint("MINIMUM_BUY_AMOUNT");
        bytes32 appData = vm.envBytes32("APP_DATA");
        bytes32 userSalt = vm.envOr("USER_SALT", bytes32(0));

        vm.startBroadcast(privateKey);
        ISilo deployedSilo = factory.createSilo(resourceToken, resourceRecipient, minimumBuyAmount, appData, userSalt);
        vm.stopBroadcast();

        silo = Silo(address(deployedSilo));

        console2.log("Silo", address(silo));
    }
}
