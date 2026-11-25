// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 as OZIERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    bytes32 private constant PREPARATION_NAMESPACE = keccak256("cow-silo.Silo.preparation");

    ISettlement public immutable override settlement;
    address public immutable override vaultRelayer;
    IERC20 public immutable override resourceToken;
    address public immutable override resourceRecipient;
    bytes32 public immutable override domainSeparator;
    uint256 public override minimumBuyAmount;
    IFundingAdapter public override fundingAdapter;
    uint256 public override hookGasLimit = 500_000;

    constructor(
        ISettlement settlement_,
        IERC20 resourceToken_,
        address resourceRecipient_,
        uint256 minimumBuyAmount_,
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
    function setMinimumBuyAmount(uint256 newMinimumBuyAmount) external override onlyOwner {
        if (newMinimumBuyAmount == 0) revert InvalidMinimumBuyAmount();

        uint256 previousAmount = minimumBuyAmount;
        minimumBuyAmount = newMinimumBuyAmount;
        emit MinimumBuyAmountSet(previousAmount, newMinimumBuyAmount);
    }

    /// @inheritdoc ISilo
    function setHookGasLimit(uint256 newGasLimit) external override onlyOwner {
        if (newGasLimit == 0) revert InvalidHookGasLimit();

        uint256 previousGasLimit = hookGasLimit;
        hookGasLimit = newGasLimit;
        emit HookGasLimitSet(previousGasLimit, newGasLimit);
    }

    /// @inheritdoc ISilo
    function prepare(OZIERC20 sellToken) external override {
        if (address(sellToken) == address(0) || address(sellToken) == address(resourceToken)) {
            revert InvalidSellToken();
        }
        if (preparedBalance(sellToken) != 0) return;

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
        if (sellToken.allowance(address(this), vaultRelayer) < actualBalance) {
            sellToken.forceApprove(vaultRelayer, type(uint256).max);
            emit TokenApproved(address(sellToken), vaultRelayer);
        }

        actualBalance = sellToken.balanceOf(address(this));
        // A callback can complete preparation before this call.
        if (preparedBalance(sellToken) != 0) return;
        if (actualBalance == 0) revert EmptyBalance();
        bytes32 slot = _preparationSlot(sellToken);
        assembly ("memory-safe") {
            tstore(slot, actualBalance)
        }
        emit TokenPrepared(address(sellToken), actualBalance);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));
        if (order.hash(domainSeparator) != hash) revert InvalidOrderHash();
        uint256 preparedAmount = preparedBalance(OZIERC20(address(order.sellToken)));
        if (preparedAmount == 0 || preparedAmount != order.sellAmount) revert InvalidPreparation();

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
        if (order.appData != appData(OZIERC20(address(order.sellToken)))) revert InvalidAppData();
        if (order.feeAmount != 0) revert InvalidFee();
        if (order.kind != GPv2Order.KIND_SELL) revert InvalidKind();
        if (order.partiallyFillable) revert OrderIsPartiallyFillable();
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
            revert InvalidBalanceType();
        }
    }

    /// @inheritdoc ISilo
    function appData(OZIERC20 sellToken) public view override returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"',
                Strings.toHexString(uint160(address(this)), 20),
                '","callData":"',
                Strings.toHexString(uint32(ISilo.prepare.selector), 4),
                _addressWord(sellToken),
                '","gasLimit":"',
                Strings.toString(hookGasLimit),
                '"}]}}}'
            )
        );
    }

    /// @inheritdoc ISilo
    function preparedBalance(OZIERC20 sellToken) public view override returns (uint256 amount) {
        bytes32 slot = _preparationSlot(sellToken);
        assembly ("memory-safe") {
            amount := tload(slot)
        }
    }

    function _addressWord(OZIERC20 token) private pure returns (bytes memory word) {
        bytes memory hexWord = bytes(Strings.toHexString(uint160(address(token)), 32));
        word = new bytes(64);
        for (uint256 i; i < 64; ++i) {
            word[i] = hexWord[i + 2];
        }
    }

    function _preparationSlot(OZIERC20 sellToken) private pure returns (bytes32) {
        return keccak256(abi.encode(PREPARATION_NAMESPACE, sellToken));
    }
}
