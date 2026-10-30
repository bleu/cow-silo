// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IBurner
/// @notice Defines the permissionless resource-token burn operation.
interface IBurner {
    event Burned(uint256 amount);

    error EmptyBalance();
    error ZeroAddress();

    function DEAD() external view returns (address);
    function token() external view returns (IERC20);
    /// @notice Transfers the complete token balance to the dead address.
    /// @return amount The amount removed from circulation.
    function burn() external returns (uint256 amount);
}
