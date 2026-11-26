// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract BalanceChangingApprovalERC20 is MockERC20 {
    constructor() MockERC20("Approval balance", "APR") { }

    function approve(address spender, uint256 amount) public override returns (bool) {
        bool result = super.approve(spender, amount);
        _mint(msg.sender, 1);
        return result;
    }
}
