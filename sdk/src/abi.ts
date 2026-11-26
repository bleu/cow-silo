import { parseAbi } from "viem";

export const orderParameter = "(address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance) order";

export const siloAbi = parseAbi([
  "event OrderCommitted(bytes32 indexed orderHash, address indexed sellToken, uint256 sellAmount)",
  `function commit(${orderParameter})`,
  "function isCommitted(bytes32 orderHash) view returns (bool)",
  "event TokenPrepared(address indexed sellToken, uint256 sellAmount)",
  "event HookGasLimitSet(uint256 previousGasLimit, uint256 newGasLimit)",
  "error InvalidHookGasLimit()",
  "error InvalidPreparation()",
  "error ZeroAddress()",
  "function prepare(address sellToken)",
  "function domainSeparator() view returns (bytes32)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function initialBuyAmount() view returns (uint256)",
  "function auctionDuration() view returns (uint32)",
  "function currentMinimumBuyAmount(address sellToken) view returns (uint256)",
  "function minimumBuyAmount() view returns (uint256)",
  "function hookGasLimit() view returns (uint256)",
  "function setHookGasLimit(uint256 newGasLimit)",
  "function fundingAdapter() view returns (address)",
  "function setFundingAdapter(address newAdapter)",
  "function FUNDING_GAS_LIMIT() view returns (uint256)",
  "function appData(address sellToken) view returns (bytes32)",
  "function preparedBalance(address sellToken) view returns (uint256)",
]);

export const approvalFundingAdapterAbi = parseAbi([
  "function source() view returns (address)",
  "function silo() view returns (address)",
  "function availableBalance(address sellToken) view returns (uint256)",
  "function fund(address sellToken)",
]);
