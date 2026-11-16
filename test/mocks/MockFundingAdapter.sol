// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IFundingAdapter } from "../../src/interfaces/IFundingAdapter.sol";

contract LargeReturnDataFundingAdapter is IFundingAdapter {
    bool internal immutable shouldRevert;

    constructor(bool shouldRevert_) {
        shouldRevert = shouldRevert_;
    }

    function fund(IERC20) external view override {
        bool revertCall = shouldRevert;
        assembly {
            if revertCall { revert(0, 0x40000) }
            return(0, 0x40000)
        }
    }
}

contract GasBurningFundingAdapter is IFundingAdapter {
    function fund(IERC20) external pure override {
        assembly {
            invalid()
        }
    }
}

contract TransferThenRevertFundingAdapter is IFundingAdapter {
    address internal immutable source;

    constructor(address source_) {
        source = source_;
    }

    function fund(IERC20 sellToken) external override {
        require(sellToken.transferFrom(source, msg.sender, sellToken.balanceOf(source)));
        revert("Funding unavailable after transfer");
    }
}

contract RevertingFundingAdapter is IFundingAdapter {
    function fund(IERC20) external pure override {
        revert("Funding unavailable");
    }
}
