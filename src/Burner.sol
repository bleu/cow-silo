// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBurner } from "./interfaces/IBurner.sol";

/// @title Burner
/// @notice Sends all received resource tokens to an irrecoverable address.
/// @dev This removes tokens from circulation. It does not change total supply for a standard ERC-20 token.
contract Burner is IBurner {
    using SafeERC20 for IERC20;

    address public constant override DEAD = 0x000000000000000000000000000000000000dEaD;
    IERC20 public immutable override token;

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @inheritdoc IBurner
    function burn() external override returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) revert EmptyBalance();
        token.safeTransfer(DEAD, amount);
        emit Burned(amount);
    }
}
