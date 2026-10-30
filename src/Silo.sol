// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { ISettlement } from "./interfaces/ISettlement.sol";

/// @title Silo
/// @notice Holds fee tokens and exposes them as surplus-capturing CoW JIT liquidity.
/// @dev A solver sets the limit price. CoW Protocol competition discovers the execution price.
contract Silo is IERC1271 {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for OZIERC20;

    uint32 public constant MAX_ORDER_DURATION = 5 minutes;

    /// @dev keccak256("cow-silo.Silo.commitment") - 1.
    uint256 private constant COMMITMENT_SLOT = 0x75193d16aee65c51188ac93f69a9942a7b1a28a71ef161c2d98e14750d4aedc8;

    ISettlement public immutable settlement;
    address public immutable vaultRelayer;
    IERC20 public immutable resourceToken;
    address public immutable resourceRecipient;
    bytes32 public immutable appData;
    bytes32 public immutable domainSeparator;

    event OrderCommitted(bytes32 indexed orderHash, address indexed sellToken, uint256 sellAmount);
    event TokenApproved(address indexed token, address indexed spender);

    error BalanceChanged(uint256 expected, uint256 actual);
    error CommitOutsideSettlement();
    error EmptyBalance();
    error InvalidAppData();
    error InvalidBalanceType();
    error InvalidBuyAmount();
    error InvalidBuyToken();
    error InvalidCommitment();
    error InvalidFee();
    error InvalidKind();
    error InvalidOrderHash();
    error InvalidReceiver();
    error InvalidSellToken();
    error InvalidValidity();
    error OrderIsPartiallyFillable();
    error ZeroAddress();

    constructor(ISettlement settlement_, IERC20 resourceToken_, address resourceRecipient_, bytes32 appData_) {
        if (
            address(settlement_) == address(0) || address(resourceToken_) == address(0)
                || resourceRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }

        settlement = settlement_;
        resourceToken = resourceToken_;
        resourceRecipient = resourceRecipient_;
        appData = appData_;
        domainSeparator = settlement_.domainSeparator();

        address vaultRelayer_ = settlement_.vaultRelayer();
        if (vaultRelayer_ == address(0)) revert ZeroAddress();
        vaultRelayer = vaultRelayer_;
    }

    /// @notice Commits this settlement transaction to one exact Silo order.
    /// @dev A solver must add this call as a pre-interaction. Transient storage clears after the transaction.
    function commit(bytes32 orderHash, OZIERC20 sellToken, uint256 sellAmount) external {
        if (msg.sender != address(settlement)) revert CommitOutsideSettlement();
        if (address(sellToken) == address(0) || address(sellToken) == address(resourceToken)) {
            revert InvalidSellToken();
        }
        if (sellAmount == 0) revert EmptyBalance();

        uint256 actualBalance = sellToken.balanceOf(address(this));
        if (actualBalance != sellAmount) revert BalanceChanged(sellAmount, actualBalance);

        if (sellToken.allowance(address(this), vaultRelayer) < sellAmount) {
            sellToken.forceApprove(vaultRelayer, type(uint256).max);
            emit TokenApproved(address(sellToken), vaultRelayer);
        }

        assembly ("memory-safe") {
            tstore(COMMITMENT_SLOT, orderHash)
        }
        emit OrderCommitted(orderHash, address(sellToken), sellAmount);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));
        if (order.hash(domainSeparator) != hash) revert InvalidOrderHash();
        if (commitment() != hash) revert InvalidCommitment();

        verify(order);
        return IERC1271.isValidSignature.selector;
    }

    /// @notice Checks the permanent Silo order rules.
    function verify(GPv2Order.Data memory order) public view {
        if (address(order.sellToken) == address(0) || order.sellToken == resourceToken) revert InvalidSellToken();
        if (order.buyToken != resourceToken) revert InvalidBuyToken();
        if (order.receiver != resourceRecipient) revert InvalidReceiver();

        uint256 balance = OZIERC20(address(order.sellToken)).balanceOf(address(this));
        if (balance == 0) revert EmptyBalance();
        if (order.sellAmount != balance) revert BalanceChanged(order.sellAmount, balance);
        if (order.buyAmount == 0) revert InvalidBuyAmount();

        if (order.validTo < block.timestamp || order.validTo > block.timestamp + MAX_ORDER_DURATION) {
            revert InvalidValidity();
        }
        if (order.appData != appData) revert InvalidAppData();
        if (order.feeAmount != 0) revert InvalidFee();
        if (order.kind != GPv2Order.KIND_SELL) revert InvalidKind();
        if (order.partiallyFillable) revert OrderIsPartiallyFillable();
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
            revert InvalidBalanceType();
        }
    }

    /// @notice Returns the order hash that is valid in the current transaction.
    function commitment() public view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(COMMITMENT_SLOT)
        }
    }
}
