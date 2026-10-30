// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Silo } from "../../src/Silo.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";

contract MockSettlement is ISettlement {
    bytes32 public immutable override domainSeparator;
    address public immutable override vaultRelayer;

    constructor(bytes32 domainSeparator_, address vaultRelayer_) {
        domainSeparator = domainSeparator_;
        vaultRelayer = vaultRelayer_;
    }

    /// @dev Mirrors the CoW Settlement flow. Pre-interactions and signature checks share one transaction context.
    function commitAndValidate(
        Silo silo,
        bytes32 digest,
        IERC20 sellToken,
        uint256 sellAmount,
        bytes calldata signature
    ) external returns (bytes32 observedCommitment, bytes4 result) {
        silo.commit(digest, sellToken, sellAmount);
        observedCommitment = silo.commitment();
        result = silo.isValidSignature(digest, signature);
    }
}
