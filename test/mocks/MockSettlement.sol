// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockHooksTrampoline } from "./MockHooksTrampoline.sol";
import { IHooksTrampoline } from "../../src/interfaces/IHooksTrampoline.sol";
import { ISilo } from "../../src/interfaces/ISilo.sol";
import { Silo } from "../../src/Silo.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";

contract MockSettlement is ISettlement {
    MockHooksTrampoline public immutable hooksTrampoline;
    bytes32 public immutable override domainSeparator;
    address public immutable override vaultRelayer;

    constructor(bytes32 domainSeparator_, address vaultRelayer_) {
        hooksTrampoline = new MockHooksTrampoline(address(this));
        domainSeparator = domainSeparator_;
        vaultRelayer = vaultRelayer_;
    }

    /// @dev Mirrors the CoW Settlement flow. Pre-interactions and signature checks share one transaction context.
    function prepareAndValidate(
        Silo silo,
        bytes32 digest,
        IERC20 sellToken,
        uint256 sellAmount,
        bytes calldata signature
    ) external returns (bool observedPreparation, bytes4 result) {
        prepare(silo, sellToken, 500_000);
        observedPreparation = silo.preparedBalance(sellToken) == sellAmount;
        result = silo.isValidSignature(digest, signature);
    }

    /// @dev Prepares and validates two orders in one simulated settlement transaction.
    function prepareAndValidateTwo(
        Silo silo,
        bytes32[2] calldata digests,
        IERC20[2] calldata sellTokens,
        uint256[2] calldata sellAmounts,
        bytes[2] calldata signatures
    ) external returns (bool[2] memory observedPreparations, bytes4[2] memory results) {
        prepare(silo, sellTokens[0], 500_000);
        prepare(silo, sellTokens[1], 500_000);

        observedPreparations[0] = silo.preparedBalance(sellTokens[0]) == sellAmounts[0];
        observedPreparations[1] = silo.preparedBalance(sellTokens[1]) == sellAmounts[1];
        results[0] = silo.isValidSignature(digests[0], signatures[0]);
        results[1] = silo.isValidSignature(digests[1], signatures[1]);
    }

    function prepare(Silo silo, IERC20 token, uint256 gasLimit) public {
        IHooksTrampoline.Hook[] memory hooks = new IHooksTrampoline.Hook[](1);
        hooks[0] = IHooksTrampoline.Hook(address(silo), abi.encodeCall(ISilo.prepare, (token)), gasLimit);
        hooksTrampoline.execute(hooks);
    }
}
