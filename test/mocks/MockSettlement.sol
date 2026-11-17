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
    ) external returns (bool observedCommitment, bytes4 result) {
        silo.commit(digest, sellToken, sellAmount);
        observedCommitment = silo.isCommitted(digest);
        result = silo.isValidSignature(digest, signature);
    }

    /// @dev Commits and validates two orders in one simulated settlement transaction.
    function commitAndValidateTwo(
        Silo silo,
        bytes32[2] calldata digests,
        IERC20[2] calldata sellTokens,
        uint256[2] calldata sellAmounts,
        bytes[2] calldata signatures
    ) external returns (bool[2] memory observedCommitments, bytes4[2] memory results) {
        silo.commit(digests[0], sellTokens[0], sellAmounts[0]);
        silo.commit(digests[1], sellTokens[1], sellAmounts[1]);

        observedCommitments[0] = silo.isCommitted(digests[0]);
        observedCommitments[1] = silo.isCommitted(digests[1]);
        results[0] = silo.isValidSignature(digests[0], signatures[0]);
        results[1] = silo.isValidSignature(digests[1], signatures[1]);
    }
}
