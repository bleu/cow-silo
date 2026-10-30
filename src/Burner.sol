// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Burner
/// @notice Sends all received resource tokens to an irrecoverable address.
/// @dev This removes tokens from circulation. It does not change total supply for a standard ERC-20 token.
contract Burner {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IERC20 public immutable token;

    event Burned(uint256 amount);

    error EmptyBalance();
    error ZeroAddress();

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @notice Moves the complete token balance to the dead address.
    /// @return amount The amount moved out of circulation.
    function burn() external returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) revert EmptyBalance();
        token.safeTransfer(DEAD, amount);
        emit Burned(amount);
    }
}
