// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFundingAdapter } from "./interfaces/IFundingAdapter.sol";

/// @notice Supplies approved source inventory to one Silo.
contract ApprovalFundingAdapter is IFundingAdapter {
    using SafeERC20 for IERC20;

    error OnlySilo();
    error ZeroAddress();

    address public immutable source;
    address public immutable silo;

    constructor(address source_, address silo_) {
        if (source_ == address(0) || silo_ == address(0)) revert ZeroAddress();
        source = source_;
        silo = silo_;
    }

    /// @inheritdoc IFundingAdapter
    function fund(IERC20 sellToken) external override {
        if (msg.sender != silo) revert OnlySilo();
        uint256 amount = availableBalance(sellToken);
        if (amount == 0) return;
        sellToken.safeTransferFrom(source, silo, amount);
    }

    /// @notice Reports source inventory covered by this adapter's allowance.
    function availableBalance(IERC20 sellToken) public view returns (uint256) {
        uint256 balance = sellToken.balanceOf(source);
        uint256 allowance = sellToken.allowance(source, address(this));
        return balance < allowance ? balance : allowance;
    }
}
