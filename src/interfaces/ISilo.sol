// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20 as CoWIERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { ISettlement } from "./ISettlement.sol";
import { IFundingAdapter } from "./IFundingAdapter.sol";

/// @title ISilo
/// @notice Defines the externally accessible Silo functions and order rules.
interface ISilo is IERC1271 {
    /// @notice Emitted after the owner replaces or disables the funding adapter.
    event FundingAdapterSet(address indexed previousAdapter, address indexed newAdapter);

    /// @notice Emitted after the owner changes the resource-token output floor.
    event MinimumBuyAmountSet(uint256 previousAmount, uint256 newAmount);

    /// @notice Emitted after the Settlement contract commits an order for validation.
    event OrderCommitted(bytes32 indexed orderHash, address indexed sellToken, uint256 sellAmount);

    /// @notice Emitted after the Silo approves the Vault Relayer for a sell token.
    event TokenApproved(address indexed token, address indexed spender);

    error BalanceChanged(uint256 expected, uint256 actual);
    error BuyAmountBelowMinimum(uint256 buyAmount, uint256 minimumBuyAmount);
    error CommitOutsideSettlement();
    error EmptyBalance();
    error InvalidAppData();
    error InvalidBalanceType();
    error InvalidBuyToken();
    error InvalidCommitment();
    error InvalidFee();
    error InvalidKind();
    error InvalidMinimumBuyAmount();
    error InvalidOrderHash();
    error InvalidReceiver();
    error InvalidSellToken();
    error InvalidValidity();
    error OrderIsPartiallyFillable();
    error ZeroAddress();

    function MAX_ORDER_DURATION() external view returns (uint32);
    function FUNDING_GAS_LIMIT() external view returns (uint256);
    function settlement() external view returns (ISettlement);
    function vaultRelayer() external view returns (address);
    function resourceToken() external view returns (CoWIERC20);
    function resourceRecipient() external view returns (address);
    function appData() external view returns (bytes32);
    function domainSeparator() external view returns (bytes32);
    function minimumBuyAmount() external view returns (uint256);
    function fundingAdapter() external view returns (IFundingAdapter);

    /// @notice Replaces the funding adapter, or disables funding with the zero address.
    function setFundingAdapter(IFundingAdapter newAdapter) external;

    /// @notice Changes the minimum resource-token output for every Silo order.
    /// @param newMinimumBuyAmount The new output floor in the resource token's smallest unit.
    function setMinimumBuyAmount(uint256 newMinimumBuyAmount) external;

    /// @notice Commits an exact order hash during a Settlement transaction.
    /// @dev The Settlement contract must call this function as an order pre-interaction.
    /// @param orderHash The EIP-712 hash of the order to authorize.
    /// @param sellToken The token sold by the order.
    /// @param sellAmount The complete Silo balance of the sell token after optional funding.
    function commit(bytes32 orderHash, IERC20 sellToken, uint256 sellAmount) external;

    /// @notice Reverts unless an order satisfies every Silo policy.
    /// @param order The decoded CoW Protocol order.
    function verify(GPv2Order.Data memory order) external view;

    /// @notice Reports whether an order hash was committed in the current transaction.
    function isCommitted(bytes32 orderHash) external view returns (bool);
}
