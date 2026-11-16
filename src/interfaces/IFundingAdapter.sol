// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Supplies sell-token inventory to a configured Silo.
interface IFundingAdapter {
    /// @notice Supplies inventory of the selected token to the adapter's configured Silo.
    /// @dev Silo ignores failed funding calls; source permissions are adapter-specific.
    function fund(IERC20 sellToken) external;
}
