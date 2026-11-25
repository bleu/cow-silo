import { parseAbi } from "viem";

export const siloAbi = parseAbi([
  "event TokenPrepared(address indexed sellToken, uint256 sellAmount)",
  "error InvalidPreparation()",
  "error ZeroAddress()",
  "function prepare(address sellToken)",
  "function domainSeparator() view returns (bytes32)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function minimumBuyAmount() view returns (uint256)",
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
