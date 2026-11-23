import { parseAbi } from "viem";

export const siloAbi = parseAbi([
  "event OrderCommitted(bytes32 indexed orderHash, address indexed sellToken, uint256 sellAmount)",
  "function commit(bytes32 orderHash, address sellToken, uint256 sellAmount)",
  "function domainSeparator() view returns (bytes32)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function minimumBuyAmount() view returns (uint256)",
  "function fundingAdapter() view returns (address)",
  "function setFundingAdapter(address newAdapter)",
  "function FUNDING_GAS_LIMIT() view returns (uint256)",
  "function appData() view returns (bytes32)",
  "function isCommitted(bytes32 orderHash) view returns (bool)",
]);

export const approvalFundingAdapterAbi = parseAbi([
  "function source() view returns (address)",
  "function silo() view returns (address)",
  "function availableBalance(address sellToken) view returns (uint256)",
  "function fund(address sellToken)",
]);
