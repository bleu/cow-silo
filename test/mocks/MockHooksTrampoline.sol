// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IHooksTrampoline } from "../../src/interfaces/IHooksTrampoline.sol";

/// @dev Mirrors the upstream executor's authorization, gas check, and ignored hook failure.
contract MockHooksTrampoline is IHooksTrampoline {
    address public immutable override settlement;

    error NotASettlement();

    constructor(address settlement_) {
        settlement = settlement_;
    }

    function execute(Hook[] calldata hooks) external override {
        if (msg.sender != settlement) revert NotASettlement();
        unchecked {
            for (uint256 i; i < hooks.length; ++i) {
                Hook calldata hook = hooks[i];
                if (gasleft() * 63 / 64 < hook.gasLimit) {
                    while (true) { }
                }
                (bool success,) = hook.target.call{ gas: hook.gasLimit }(hook.callData);
                success;
            }
        }
    }
}
