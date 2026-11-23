import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import { siloAbi } from "./abi.js";
import type { OrderTerms } from "./reader.js";

export { approvalFundingAdapterAbi, siloAbi } from "./abi.js";
export {
  readOrderTerms,
  readOrderTermsBatch,
  type OrderTerms,
  type OrderTermsResult,
  type SiloPair,
} from "./reader.js";

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

const orderTuple = parseAbiParameters(
  "(address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance) order",
);

const orderHashParameters = parseAbiParameters(
  "bytes32 typeHash, address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance",
);

export function buildJitTrade(terms: OrderTerms, limit: { buyAmount: bigint; validTo: number }) {
  const { validTo } = limit;
  if (
    !Number.isInteger(validTo) || validTo < 0 || validTo > 0xffffffff ||
    validTo < terms.blockTimestamp || validTo > terms.blockTimestamp + 300n
  ) {
    throw new Error("validTo must be within five minutes of the observed block");
  }

  const order = buildOrder({
    sellToken: terms.sellToken,
    resourceToken: terms.buyToken,
    resourceRecipient: terms.receiver,
    sellAmount: terms.sellAmount,
    minimumBuyAmount: terms.minimumBuyAmount,
    appData: terms.appData,
    ...limit,
  });
  return {
    jitOrder: toSolverJitOrder(terms.silo, order),
    executedAmount: order.sellAmount.toString(),
    preInteraction: buildCommitInteraction(terms.silo, order, terms.domainSeparator),
  };
}

export function buildOrder(input: {
  sellToken: Address;
  resourceToken: Address;
  resourceRecipient: Address;
  sellAmount: bigint;
  buyAmount: bigint;
  minimumBuyAmount: bigint;
  validTo: number;
  appData: Hex;
}): SiloOrder {
  if (input.sellAmount <= 0n) throw new Error("sellAmount must be positive");
  if (input.minimumBuyAmount <= 0n) throw new Error("minimumBuyAmount must be positive");
  if (input.buyAmount < input.minimumBuyAmount) {
    throw new Error("buyAmount must be at least minimumBuyAmount");
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

export function buildCommitInteraction(silo: Address, order: SiloOrder, domainSeparator: Hex): Interaction {
  const orderHash = hashOrder(order, domainSeparator);
  return {
    target: silo,
    value: "0",
    callData: encodeFunctionData({
      abi: siloAbi,
      functionName: "commit",
      args: [orderHash, order.sellToken, order.sellAmount],
    }),
  };
}

/** Builds one pre-interaction for each independent Silo order in a settlement. */
export function buildCommitInteractions(
  silo: Address,
  orders: readonly SiloOrder[],
  domainSeparator: Hex,
): Interaction[] {
  return orders.map((order) => buildCommitInteraction(silo, order, domainSeparator));
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
