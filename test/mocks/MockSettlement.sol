// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { ISettlement } from "../../src/interfaces/ISettlement.sol";

contract MockSettlement is ISettlement {
    bytes32 public immutable override domainSeparator;
    address public immutable override vaultRelayer;

    constructor(bytes32 domainSeparator_, address vaultRelayer_) {
        domainSeparator = domainSeparator_;
        vaultRelayer = vaultRelayer_;
    }
}
