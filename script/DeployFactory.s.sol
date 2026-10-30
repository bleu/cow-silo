// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { SiloFactory } from "../src/SiloFactory.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";

contract DeployFactory is Script {
    function run() external returns (SiloFactory factory) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        ISettlement settlement = ISettlement(vm.envAddress("SETTLEMENT"));

        vm.startBroadcast(privateKey);
        factory = new SiloFactory(settlement);
        vm.stopBroadcast();

        console2.log("SiloFactory", address(factory));
    }
}
