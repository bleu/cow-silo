import { erc20Abi, zeroAddress, type Address, type Hex, type PublicClient } from "viem";
import { siloAbi } from "./abi.js";

export type SiloPair = { silo: Address; sellToken: Address };

export type OrderTerms = SiloPair & {
  buyToken: Address;
  receiver: Address;
  sellAmount: bigint;
  minimumBuyAmount: bigint;
  currentMinimumBuyAmount: bigint;
  auctionDuration: number;
  hookGasLimit: bigint;
  appData: Hex;
  domainSeparator: Hex;
  blockNumber: bigint;
  blockTimestamp: bigint;
};

export type OrderTermsResult =
  | { status: "available"; terms: OrderTerms }
  | { status: "empty" }
  | { status: "error"; error: Error };

type ReaderClient = Pick<PublicClient, "getBlock" | "multicall">;
type SiloField = "resourceToken" | "resourceRecipient" | "domainSeparator" | "minimumBuyAmount" | "auctionDuration" | "hookGasLimit";
type ReadCall =
  | { address: Address; abi: typeof siloAbi; functionName: SiloField }
  | { address: Address; abi: typeof siloAbi; functionName: "appData" | "currentMinimumBuyAmount"; args: readonly [Address] }
  | { address: Address; abi: typeof erc20Abi; functionName: "balanceOf"; args: readonly [Address] };

export async function readOrderTermsBatch(
  client: ReaderClient,
  { pairs, blockNumber }: { pairs: readonly SiloPair[]; blockNumber?: bigint },
): Promise<OrderTermsResult[]> {
  if (pairs.length === 0) return [];
  const block = await client.getBlock(blockNumber === undefined ? { blockTag: "latest" } : { blockNumber });
  const calls: ReadCall[] = [];
  const indices = new Map<string, number>();

  function enqueue(call: ReadCall) {
    const args = "args" in call ? call.args.map((arg) => arg.toLowerCase()).join(":") : "";
    const key = `${call.address.toLowerCase()}:${call.functionName}:${args}`;
    const existing = indices.get(key);
    if (existing !== undefined) return existing;
    const index = calls.length;
    indices.set(key, index);
    calls.push(call);
    return index;
  }

  const rows = pairs.map(({ silo, sellToken }) => {
    const field = (functionName: SiloField) => enqueue({ address: silo, abi: siloAbi, functionName });
    return {
      buyToken: field("resourceToken"),
      receiver: field("resourceRecipient"),
      appData: enqueue({ address: silo, abi: siloAbi, functionName: "appData", args: [sellToken] }),
      domainSeparator: field("domainSeparator"),
      minimumBuyAmount: field("minimumBuyAmount"),
      auctionDuration: field("auctionDuration"),
      currentMinimumBuyAmount: enqueue({ address: silo, abi: siloAbi, functionName: "currentMinimumBuyAmount", args: [sellToken] }),
      hookGasLimit: field("hookGasLimit"),
      sellAmount: enqueue({ address: sellToken, abi: erc20Abi, functionName: "balanceOf", args: [silo] }),
    };
  });
  const results = await client.multicall({ contracts: calls, blockNumber: block.number, allowFailure: true });

  function valueAt(index: number) {
    const result = results[index]!;
    if (result.status === "failure") throw result.error;
    return result.result;
  }

  function hexAt(index: number): Hex {
    const value = valueAt(index);
    if (typeof value !== "string") throw new Error("Expected a hex value");
    return value;
  }

  function amountAt(index: number) {
    const value = valueAt(index);
    if (typeof value !== "bigint") throw new Error("Expected a token amount");
    return value;
  }

  return rows.map((row, i) => {
    const pair = pairs[i]!;
    try {
      if (pair.sellToken === zeroAddress) throw new Error("sellToken must not be the zero address");
      const buyToken = hexAt(row.buyToken);
      if (buyToken.toLowerCase() === pair.sellToken.toLowerCase()) return { status: "empty" };
      const auctionDuration = valueAt(row.auctionDuration);
      if (typeof auctionDuration !== "number") throw new Error("Expected an auction duration");
      const terms: OrderTerms = {
        ...pair,
        buyToken,
        receiver: hexAt(row.receiver),
        appData: hexAt(row.appData),
        domainSeparator: hexAt(row.domainSeparator),
        minimumBuyAmount: amountAt(row.minimumBuyAmount),
        currentMinimumBuyAmount: amountAt(row.currentMinimumBuyAmount),
        auctionDuration,
        hookGasLimit: amountAt(row.hookGasLimit),
        sellAmount: amountAt(row.sellAmount),
        blockNumber: block.number,
        blockTimestamp: block.timestamp,
      };
      return terms.sellAmount === 0n ? { status: "empty" } : { status: "available", terms };
    } catch (error) {
      return { status: "error", error: error instanceof Error ? error : new Error(String(error)) };
    }
  });
}

export async function readOrderTerms(
  client: ReaderClient,
  { silo, sellToken, blockNumber }: SiloPair & { blockNumber?: bigint },
): Promise<OrderTerms | null> {
  const results = await readOrderTermsBatch(client, { pairs: [{ silo, sellToken }], blockNumber });
  const result = results[0]!;
  if (result.status === "error") throw result.error;
  return result.status === "available" ? result.terms : null;
}
