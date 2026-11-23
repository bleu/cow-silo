import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbi,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";

export type SiloOrder = {
  sellToken: Address;
  buyToken: Address;
  receiver: Address;
  sellAmount: bigint;
  buyAmount: bigint;
  validTo: number;
  appData: Hex;
  feeAmount: 0n;
  kind: typeof KIND_SELL;
  partiallyFillable: false;
  sellTokenBalance: typeof BALANCE_ERC20;
  buyTokenBalance: typeof BALANCE_ERC20;
};

export type SolverJitOrder = {
  sellToken: Address;
  buyToken: Address;
  receiver: Address;
  sellAmount: string;
  buyAmount: string;
  validTo: number;
  appData: Hex;
  kind: "sell";
  partiallyFillable: false;
  sellTokenBalance: "erc20";
  buyTokenBalance: "erc20";
  signingScheme: "eip1271";
  signature: Hex;
};

export type Interaction = {
  target: Address;
  value: "0";
  callData: Hex;
};

export const ORDER_TYPE_HASH =
  "0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489" as const;
export const KIND_SELL =
  "0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775" as const;
export const BALANCE_ERC20 =
  "0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9" as const;

const orderParameter = "(address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance) order";
const orderTuple = parseAbiParameters(orderParameter);

const orderHashParameters = parseAbiParameters(
  "bytes32 typeHash, address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance",
);

export const siloAbi = parseAbi([
  `function commit(${orderParameter})`,
  "function domainSeparator() view returns (bytes32)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function initialBuyAmount() view returns (uint256)",
  "function minimumBuyAmount() view returns (uint256)",
  "function auctionDuration() view returns (uint32)",
  "function currentMinimumBuyAmount(address sellToken) view returns (uint256)",
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

function assertUint32(value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff_ffff) {
    throw new Error(`${field} must be a uint32 integer`);
  }
}

/** Use the chain's block timestamp and the effective duration from Silo.auctionDuration(), in seconds. */
export function buildOrderDeadlines(input: {
  blockTimestamp: number;
  executionWindow: number;
  auctionDuration: number;
}): { executionDeadline: number; validTo: number } {
  if (!Number.isSafeInteger(input.executionWindow) || input.executionWindow < 0 || input.executionWindow > 300) {
    throw new Error("executionWindow must be an integer between 0 and 300 seconds");
  }
  assertUint32(input.blockTimestamp, "blockTimestamp");
  assertUint32(input.auctionDuration, "auctionDuration");
  const executionDeadline = input.blockTimestamp + input.executionWindow;
  const validTo = executionDeadline + input.auctionDuration;
  assertUint32(validTo, "validTo");
  return { executionDeadline, validTo };
}

export function buildOrder(input: {
  sellToken: Address;
  resourceToken: Address;
  resourceRecipient: Address;
  sellAmount: bigint;
  buyAmount: bigint;
  /** Read currentMinimumBuyAmount(sellToken) from this Silo. */
  currentMinimumBuyAmount: bigint;
  validTo: number;
  appData: Hex;
}): SiloOrder {
  assertUint32(input.validTo, "validTo");
  if (input.sellAmount <= 0n) throw new Error("sellAmount must be positive");
  if (typeof input.currentMinimumBuyAmount !== "bigint" || input.currentMinimumBuyAmount <= 0n) {
    throw new Error("currentMinimumBuyAmount must be a positive bigint");
  }
  if (input.buyAmount < input.currentMinimumBuyAmount) {
    throw new Error("buyAmount must be at least currentMinimumBuyAmount");
  }
  if (input.sellToken.toLowerCase() === input.resourceToken.toLowerCase()) {
    throw new Error("sellToken must differ from resourceToken");
  }

  return {
    sellToken: input.sellToken,
    buyToken: input.resourceToken,
    receiver: input.resourceRecipient,
    sellAmount: input.sellAmount,
    buyAmount: input.buyAmount,
    validTo: input.validTo,
    appData: input.appData,
    feeAmount: 0n,
    kind: KIND_SELL,
    partiallyFillable: false,
    sellTokenBalance: BALANCE_ERC20,
    buyTokenBalance: BALANCE_ERC20,
  };
}

/// Encodes the bytes that the settlement contract passes to Silo.isValidSignature.
export function encodeOrderPayload(order: SiloOrder): Hex {
  return encodeAbiParameters(orderTuple, [order]);
}

/// Encodes an EIP-1271 signature for the CoW solver API.
/// The driver recovers the first 20 bytes as the order owner and removes them before the contract call.
export function encodeSolverSignature(silo: Address, order: SiloOrder): Hex {
  return concatHex([silo, encodeOrderPayload(order)]);
}

export function hashOrder(order: SiloOrder, domainSeparator: Hex): Hex {
  const structHash = keccak256(
    encodeAbiParameters(orderHashParameters, [
      ORDER_TYPE_HASH,
      order.sellToken,
      order.buyToken,
      order.receiver,
      order.sellAmount,
      order.buyAmount,
      order.validTo,
      order.appData,
      order.feeAmount,
      order.kind,
      order.partiallyFillable,
      order.sellTokenBalance,
      order.buyTokenBalance,
    ]),
  );
  return keccak256(concatHex(["0x1901", domainSeparator, structHash]));
}

export function buildCommitInteraction(silo: Address, order: SiloOrder): Interaction {
  return {
    target: silo,
    value: "0",
    callData: encodeFunctionData({
      abi: siloAbi,
      functionName: "commit",
      args: [order],
    }),
  };
}

/** Builds one pre-interaction for each independent Silo order in a settlement. */
export function buildCommitInteractions(
  silo: Address,
  orders: readonly SiloOrder[],
): Interaction[] {
  const sellTokens = new Set<string>();
  return orders.map((order) => {
    const token = order.sellToken.toLowerCase();
    if (sellTokens.has(token)) throw new Error(`duplicate sellToken: ${order.sellToken}`);
    sellTokens.add(token);
    return buildCommitInteraction(silo, order);
  });
}

export function toSolverJitOrder(silo: Address, order: SiloOrder): SolverJitOrder {
  return {
    sellToken: order.sellToken,
    buyToken: order.buyToken,
    receiver: order.receiver,
    sellAmount: order.sellAmount.toString(),
    buyAmount: order.buyAmount.toString(),
    validTo: order.validTo,
    appData: order.appData,
    kind: "sell",
    partiallyFillable: false,
    sellTokenBalance: "erc20",
    buyTokenBalance: "erc20",
    signingScheme: "eip1271",
    signature: encodeSolverSignature(silo, order),
  };
}
