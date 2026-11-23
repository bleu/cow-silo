// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "cowprotocol/contracts/interfaces/IERC20.sol";
import { GPv2Order } from "cowprotocol/contracts/libraries/GPv2Order.sol";

import { ISettlement } from "./interfaces/ISettlement.sol";
import { ISilo } from "./interfaces/ISilo.sol";
import { IFundingAdapter } from "./interfaces/IFundingAdapter.sol";

/// @title Silo
/// @notice Holds fee tokens and exposes them as surplus-capturing CoW JIT liquidity.
/// @dev The configured minimum buy amount is a resource-denominated execution floor, not a price oracle.
contract Silo is ISilo, Ownable2Step {
    using GPv2Order for GPv2Order.Data;
    using SafeERC20 for OZIERC20;

    uint32 public constant MAX_ORDER_DURATION = 5 minutes;
    uint256 public constant FUNDING_GAS_LIMIT = 200_000;

    bytes32 private constant ACTIVE_ORDER_NAMESPACE = keccak256("cow-silo.Silo.activeOrder");
    bytes32 private constant COMMITMENT_NAMESPACE = keccak256("cow-silo.Silo.commitment");

    ISettlement public immutable override settlement;
    address public immutable override vaultRelayer;
    IERC20 public immutable override resourceToken;
    address public immutable override resourceRecipient;
    bytes32 public immutable override appData;
    bytes32 public immutable override domainSeparator;
    uint256 public immutable override minimumBuyAmount;
    uint256 public immutable override initialBuyAmount;
    uint32 public immutable override auctionDuration;
    uint256 private immutable deployedAt;

    struct Attempt {
        bytes32 orderHash;
        uint256 sellAmount;
        uint32 validTo;
        uint32 committedAt;
        uint32 previousStart;
    }

    mapping(IERC20 => Attempt) private attempts;
    IFundingAdapter public override fundingAdapter;

    constructor(
        ISettlement settlement_,
        IERC20 resourceToken_,
        address resourceRecipient_,
        uint256 initialBuyAmount_,
        uint256 minimumBuyAmount_,
        uint32 auctionDuration_,
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
        if (initialBuyAmount_ < minimumBuyAmount_ || (initialBuyAmount_ > minimumBuyAmount_ && auctionDuration_ == 0)) {
            revert InvalidAuction();
        }

        settlement = settlement_;
        resourceToken = resourceToken_;
        resourceRecipient = resourceRecipient_;
        initialBuyAmount = initialBuyAmount_;
        minimumBuyAmount = minimumBuyAmount_;
        auctionDuration = initialBuyAmount_ == minimumBuyAmount_ ? 0 : auctionDuration_;
        if (block.timestamp > type(uint32).max - auctionDuration) revert InvalidAuction();
        deployedAt = block.timestamp;
        appData = appData_;
        domainSeparator = settlement_.domainSeparator();

        address vaultRelayer_ = settlement_.vaultRelayer();
        if (vaultRelayer_ == address(0)) revert ZeroAddress();
        vaultRelayer = vaultRelayer_;
    }

    /// @inheritdoc ISilo
    function setFundingAdapter(IFundingAdapter newAdapter) external override onlyOwner {
        address previousAdapter = address(fundingAdapter);
        fundingAdapter = newAdapter;
        emit FundingAdapterSet(previousAdapter, address(newAdapter));
    }

    /// @inheritdoc ISilo
    function currentMinimumBuyAmount(IERC20 sellToken) public view override returns (uint256) {
        if (auctionDuration == 0) return minimumBuyAmount;
        uint256 elapsed = block.timestamp - _auctionStart(sellToken);
        if (elapsed >= auctionDuration) return minimumBuyAmount;
        return initialBuyAmount - Math.mulDiv(initialBuyAmount - minimumBuyAmount, elapsed, auctionDuration);
    }

    function _auctionStart(IERC20 sellToken) private view returns (uint256) {
        Attempt storage last = attempts[sellToken];
        if (last.sellAmount == 0) return deployedAt;
        // Once both possible starts have reached the floor, the fill record is no longer needed.
        if (block.timestamp >= uint256(last.committedAt) + auctionDuration) return last.committedAt;
        return _filledAmount(last.orderHash, last.validTo) == last.sellAmount ? last.committedAt : last.previousStart;
    }

    function _filledAmount(bytes32 orderHash, uint32 validTo) private view returns (uint256) {
        bytes memory uid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(uid, orderHash, address(this), validTo);
        return settlement.filledAmount(uid);
    }

    /// @inheritdoc ISilo
    function commit(GPv2Order.Data calldata order) external override {
        if (msg.sender != address(settlement)) revert CommitOutsideSettlement();
        OZIERC20 sellToken = OZIERC20(address(order.sellToken));
        uint256 sellAmount = order.sellAmount;
        if (address(sellToken) == address(0) || address(sellToken) == address(resourceToken)) {
            revert InvalidSellToken();
        }
        if (sellAmount == 0) revert EmptyBalance();

        _checkValidity(order.validTo);

        IFundingAdapter adapter = fundingAdapter;
        if (address(adapter) != address(0)) {
            bytes memory callData = abi.encodeCall(IFundingAdapter.fund, (sellToken));
            uint256 gasLimit = FUNDING_GAS_LIMIT;
            // Ignore failure and do not copy untrusted return data.
            assembly ("memory-safe") {
                pop(call(gasLimit, adapter, 0, add(callData, 0x20), mload(callData), 0, 0))
            }
        }

        uint256 actualBalance = sellToken.balanceOf(address(this));
        if (actualBalance != sellAmount) revert BalanceChanged(sellAmount, actualBalance);

        if (sellToken.allowance(address(this), vaultRelayer) < sellAmount) {
            sellToken.forceApprove(vaultRelayer, type(uint256).max);
            emit TokenApproved(address(sellToken), vaultRelayer);
        }

        bytes32 orderHash = GPv2Order.hash(order, domainSeparator);
        if (auctionDuration != 0) {
            if (_filledAmount(orderHash, order.validTo) != 0) revert OrderAlreadyFilled();
            uint32 previousStart = uint32(_auctionStart(order.sellToken));
            attempts[order.sellToken] =
                Attempt(orderHash, sellAmount, order.validTo, uint32(block.timestamp), previousStart);
        }
        bytes32 slot = _commitmentSlot(orderHash);
        bytes32 activeSlot = keccak256(abi.encode(ACTIVE_ORDER_NAMESPACE, sellToken));
        assembly ("memory-safe") {
            tstore(slot, activeSlot)
            tstore(activeSlot, orderHash)
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
        uint256 minimumBuyAmount_ = currentMinimumBuyAmount(order.sellToken);
        if (order.buyAmount < minimumBuyAmount_) {
            revert BuyAmountBelowMinimum(order.buyAmount, minimumBuyAmount_);
        }

        _checkValidity(order.validTo);
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
        assembly ("memory-safe") {
            let activeSlot := tload(slot)
            committed := and(iszero(iszero(activeSlot)), eq(tload(activeSlot), orderHash))
        }
    }

    function _checkValidity(uint32 validTo) private view {
        // Settlement must retain the fill record until this token can reach the floor again.
        uint256 earliest = block.timestamp + auctionDuration;
        if (validTo < earliest || validTo > earliest + MAX_ORDER_DURATION) revert InvalidValidity();
    }

    function _commitmentSlot(bytes32 orderHash) private pure returns (bytes32) {
        return keccak256(abi.encode(COMMITMENT_NAMESPACE, orderHash));
    }
}
