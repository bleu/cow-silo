// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { ISettlement } from "./interfaces/ISettlement.sol";
import { ISilo } from "./interfaces/ISilo.sol";

/// @title Silo
/// @notice Holds fee tokens and exposes them as surplus-capturing CoW JIT liquidity.
/// @dev The configured minimum buy amount is a resource-denominated execution floor, not a price oracle.
contract Silo is ISilo, Ownable2Step {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for OZIERC20;

    uint32 public constant MAX_ORDER_DURATION = 5 minutes;

    bytes32 private constant COMMITMENT_NAMESPACE = keccak256("cow-silo.Silo.commitment");

    ISettlement public immutable override settlement;
    address public immutable override vaultRelayer;
    IERC20 public immutable override resourceToken;
    address public immutable override resourceRecipient;
    bytes32 public immutable override appData;
    bytes32 public immutable override domainSeparator;
    uint256 public override minimumBuyAmount;

    constructor(
        ISettlement settlement_,
        IERC20 resourceToken_,
        address resourceRecipient_,
        uint256 minimumBuyAmount_,
        bytes32 appData_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(settlement_) == address(0) || address(resourceToken_) == address(0)
                || resourceRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (minimumBuyAmount_ == 0) revert InvalidMinimumBuyAmount();

        settlement = settlement_;
        resourceToken = resourceToken_;
        resourceRecipient = resourceRecipient_;
        minimumBuyAmount = minimumBuyAmount_;
        appData = appData_;
        domainSeparator = settlement_.domainSeparator();

        address vaultRelayer_ = settlement_.vaultRelayer();
        if (vaultRelayer_ == address(0)) revert ZeroAddress();
        vaultRelayer = vaultRelayer_;
    }

    /// @inheritdoc ISilo
    function setMinimumBuyAmount(uint256 newMinimumBuyAmount) external override onlyOwner {
        if (newMinimumBuyAmount == 0) revert InvalidMinimumBuyAmount();

        uint256 previousAmount = minimumBuyAmount;
        minimumBuyAmount = newMinimumBuyAmount;
        emit MinimumBuyAmountSet(previousAmount, newMinimumBuyAmount);
    }

    /// @inheritdoc ISilo
    /// @dev A solver adds one call per order as a pre-interaction. Commitments use separate transient slots and
    /// therefore do not overwrite other Silo orders in the same settlement transaction.
    function commit(bytes32 orderHash, OZIERC20 sellToken, uint256 sellAmount) external override {
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

        bytes32 slot = _commitmentSlot(orderHash);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        emit OrderCommitted(orderHash, address(sellToken), sellAmount);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));
        if (order.hash(domainSeparator) != hash) revert InvalidOrderHash();
        if (!isCommitted(hash)) revert InvalidCommitment();

        verify(order);
        return IERC1271.isValidSignature.selector;
    }

    /// @inheritdoc ISilo
    function verify(GPv2Order.Data memory order) public view override {
        if (address(order.sellToken) == address(0) || order.sellToken == resourceToken) revert InvalidSellToken();
        if (order.buyToken != resourceToken) revert InvalidBuyToken();
        if (order.receiver != resourceRecipient) revert InvalidReceiver();

        uint256 balance = OZIERC20(address(order.sellToken)).balanceOf(address(this));
        if (balance == 0) revert EmptyBalance();
        if (order.sellAmount != balance) revert BalanceChanged(order.sellAmount, balance);
        uint256 minimumBuyAmount_ = minimumBuyAmount;
        if (order.buyAmount < minimumBuyAmount_) {
            revert BuyAmountBelowMinimum(order.buyAmount, minimumBuyAmount_);
        }

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

    /// @inheritdoc ISilo
    function isCommitted(bytes32 orderHash) public view override returns (bool committed) {
        bytes32 slot = _commitmentSlot(orderHash);
        uint256 value;
        assembly ("memory-safe") {
            value := tload(slot)
        }
        committed = value == 1;
    }

    function _commitmentSlot(bytes32 orderHash) private pure returns (bytes32) {
        return keccak256(abi.encode(COMMITMENT_NAMESPACE, orderHash));
    }
}
