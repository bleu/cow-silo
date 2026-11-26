// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20 as CoWIERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";

import { ISettlement } from "../../../src/interfaces/ISettlement.sol";

interface IMainnetSettlement is ISettlement {
    struct Trade {
        uint256 sellTokenIndex;
        uint256 buyTokenIndex;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        uint256 flags;
        uint256 executedAmount;
        bytes signature;
    }

    struct Interaction {
        address target;
        uint256 value;
        bytes callData;
    }

    function settle(
        CoWIERC20[] calldata tokens,
        uint256[] calldata clearingPrices,
        Trade[] calldata trades,
        Interaction[][3] calldata interactions
    ) external;

    function authenticator() external view returns (ISolverAuthenticator);
}

interface ISolverAuthenticator {
    function isSolver(address solver) external view returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}
