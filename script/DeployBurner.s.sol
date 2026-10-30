// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";

import { Burner } from "../src/Burner.sol";

contract DeployBurner is Script {
    function run() external returns (Burner burner) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        IERC20 resourceToken = IERC20(vm.envAddress("RESOURCE_TOKEN"));

        vm.startBroadcast(privateKey);
        burner = new Burner(resourceToken);
        vm.stopBroadcast();

        console2.log("Burner", address(burner));
    }
}
