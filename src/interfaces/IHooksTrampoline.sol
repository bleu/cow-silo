// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

/// @notice The trusted CoW hook executor.
interface IHooksTrampoline {
    struct Hook {
        address target;
        bytes callData;
        uint256 gasLimit;
    }

    function settlement() external view returns (address);
    function execute(Hook[] calldata hooks) external;
}
