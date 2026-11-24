import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  multicall3Abi,
  numberToHex,
  parseAbi,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import { mainnet } from "viem/chains";
import { describe, expect, it } from "vitest";

import {
  buildCommitInteraction,
  buildJitTrade,
  buildOrder,
  readOrderTerms,
  readOrderTermsBatch,
  toSolverJitOrder,
} from "../src/index.js";

const silo = "0x1111111111111111111111111111111111111111";
const sellToken = "0x2222222222222222222222222222222222222222";
const buyToken = "0x3333333333333333333333333333333333333333";
const receiver = "0x4444444444444444444444444444444444444444";
const appData = `0x${"55".repeat(32)}` as const;
const domainSeparator = `0x${"66".repeat(32)}` as const;
const blockNumber = 20_000_000n;
const blockTimestamp = 1_900_000_000n;
const otherSilo = "0x7777777777777777777777777777777777777777";
const otherToken = "0x8888888888888888888888888888888888888888";
const brokenToken = "0x9999999999999999999999999999999999999999";
const pair = { silo, sellToken } as const;
const terms = {
  ...pair, buyToken, receiver, sellAmount: 100n, minimumBuyAmount: 10n,
  currentMinimumBuyAmount: 25n, auctionDuration: 600, appData, domainSeparator, blockNumber, blockTimestamp,
} as const;

const readAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function minimumBuyAmount() view returns (uint256)",
  "function currentMinimumBuyAmount(address) view returns (uint256)",
  "function auctionDuration() view returns (uint32)",
  "function appData() view returns (bytes32)",
  "function domainSeparator() view returns (bytes32)",
]);

type RpcRequest =
  | { method: "eth_getBlockByNumber"; params: [Hex | "latest", boolean] }
  | { method: "eth_call"; params: [{ data: Hex }, Hex | "latest"] };

type ReadValues = Partial<Record<Address, bigint | "revert">>;

function testChain({ balances = {}, floors = {}, quotes = {} }: {
  balances?: ReadValues;
  floors?: ReadValues;
  quotes?: Partial<Record<Address, ReadValues>>;
} = {}) {
  const state = { latest: blockNumber };
  const blocks: string[] = [];
  const reads: { block: string; target: Address; getter: string; arg?: Address }[] = [];
  const client = createPublicClient({
    chain: mainnet,
    transport: custom({
      async request({ method, params }: RpcRequest) {
        if (method === "eth_getBlockByNumber") {
          const [tag] = params;
          blocks.push(tag);
          const number = tag === "latest" ? state.latest : BigInt(tag);
          return { number: numberToHex(number), timestamp: numberToHex(blockTimestamp + (number - blockNumber) * 12n) };
        }
        if (method !== "eth_call") throw new Error(`Unexpected RPC method: ${method}`);
        const [tx, block] = params;
        const aggregate = decodeFunctionData({ abi: multicall3Abi, data: tx.data });
        if (aggregate.functionName !== "aggregate3") throw new Error(`Unexpected multicall: ${aggregate.functionName}`);
        const result = aggregate.args[0].map(({ target, callData }) => {
          const { functionName, args } = decodeFunctionData({ abi: readAbi, data: callData });
          const arg = args?.[0];
          reads.push({ block, target, getter: functionName, arg });
          const number = block === "latest" ? state.latest : BigInt(block);
          const floor = floors[target] ?? 10n;
          const liveMinimum = target === otherSilo ? floor : (number === blockNumber ? 25n : 20n);
          const values = {
            resourceToken: buyToken,
            resourceRecipient: receiver,
            minimumBuyAmount: floor,
            currentMinimumBuyAmount: (arg && quotes[target]?.[arg]) ?? liveMinimum,
            auctionDuration: target === otherSilo ? 0 : 600,
            appData,
            domainSeparator,
            balanceOf: balances[target] ?? (number === blockNumber ? 100n : 73n),
          } as const;
          const value = values[functionName];
          if (value === "revert") return { success: false, returnData: "0x" as const };
          return { success: true, returnData: encodeFunctionResult({ abi: readAbi, functionName, result: value }) };
        });
        return encodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", result });
      },
    }, { retryCount: 0 }),
  });
  return { client, state, reads, blocks };
}

describe("readOrderTerms", () => {
  it("reads inventory and the live minimum at the latest or a specified block", async () => {
    const { client, state, reads, blocks } = testChain();
    expect(await readOrderTerms(client, pair)).toEqual(terms);

    state.latest += 1n;
    expect(await readOrderTerms(client, pair)).toEqual({
      ...terms,
      sellAmount: 73n,
      currentMinimumBuyAmount: 20n,
      blockNumber: blockNumber + 1n,
      blockTimestamp: blockTimestamp + 12n,
    });
    expect(await readOrderTerms(client, { ...pair, blockNumber })).toEqual(terms);
    expect(blocks).toEqual(["latest", "latest", numberToHex(blockNumber)]);
    expect(new Set(reads.map(({ block }) => block))).toEqual(new Set([numberToHex(blockNumber), numberToHex(blockNumber + 1n)]));
  });

  it("returns null for an empty balance or a positive resource token balance", async () => {
    const { client } = testChain({ balances: { [sellToken]: 0n, [buyToken]: 42n } });
    expect(await readOrderTerms(client, pair)).toBeNull();
    expect(await readOrderTerms(client, { silo, sellToken: buyToken })).toBeNull();
  });

  it("throws for a failed balance read or a zero-address sell token", async () => {
    const { client } = testChain({ balances: { [sellToken]: "revert" } });
    await expect(readOrderTerms(client, pair)).rejects.toThrow();
    await expect(readOrderTerms(client, { silo, sellToken: zeroAddress })).rejects.toThrow();
  });
});

describe("readOrderTermsBatch", () => {
  it("reads each Silo configuration once and each distinct pair's balance and live minimum once", async () => {
    const { client, reads, blocks, state } = testChain({
      balances: { [otherToken]: 35n },
      floors: { [otherSilo]: 8n },
      quotes: { [silo]: { [otherToken]: 17n }, [otherSilo]: { [sellToken]: 8n } },
    });
    state.latest += 1n;
    const pairs = [{ silo, sellToken: otherToken }, { silo: otherSilo, sellToken }, pair, pair] as const;
    const result = await readOrderTermsBatch(client, { pairs, blockNumber });
    expect(result).toEqual([
      { status: "available", terms: { ...terms, sellToken: otherToken, sellAmount: 35n, currentMinimumBuyAmount: 17n } },
      { status: "available", terms: { ...terms, silo: otherSilo, minimumBuyAmount: 8n, currentMinimumBuyAmount: 8n, auctionDuration: 0 } },
      { status: "available", terms },
      { status: "available", terms },
    ]);
    expect(blocks).toEqual([numberToHex(blockNumber)]);
    expect(new Set(reads.map(({ block }) => block))).toEqual(new Set([numberToHex(blockNumber)]));
    for (const address of [silo, otherSilo]) {
      expect(reads.filter(({ target, arg }) => target === address && arg === undefined).map(({ getter }) => getter).sort()).toEqual([
        "appData", "auctionDuration", "domainSeparator", "minimumBuyAmount", "resourceRecipient", "resourceToken",
      ]);
    }
    const targetsAndArgs = (name: string) => reads.filter(({ getter }) => getter === name).map(({ target, arg }) => [target, arg]);
    expect(targetsAndArgs("balanceOf")).toEqual([[otherToken, silo], [sellToken, otherSilo], [sellToken, silo]]);
    expect(targetsAndArgs("currentMinimumBuyAmount")).toEqual([[silo, otherToken], [otherSilo, sellToken], [silo, sellToken]]);
  });

  it("limits a failed live minimum read to its Silo and sell token", async () => {
    const { client } = testChain({ quotes: { [silo]: { [otherToken]: "revert" } } });
    expect(await readOrderTermsBatch(client, { pairs: [{ silo, sellToken: otherToken }, pair] })).toEqual([
      { status: "error", error: expect.any(Error) }, { status: "available", terms },
    ]);
  });

  it("reports empty inventory and read failures in place without losing unrelated orders", async () => {
    const { client } = testChain({ balances: { [otherToken]: 0n, [brokenToken]: "revert" }, floors: { [otherSilo]: "revert" } });
    const pairs = [
      { silo: otherSilo, sellToken },
      { silo, sellToken: otherToken },
      pair,
      { silo, sellToken: brokenToken },
      { silo, sellToken: buyToken },
      { silo: otherSilo, sellToken: otherToken },
      { silo, sellToken: zeroAddress },
    ] as const;
    const error = { status: "error", error: expect.any(Error) };
    expect(await readOrderTermsBatch(client, { pairs })).toEqual([
      error, { status: "empty" }, { status: "available", terms }, error, { status: "empty" }, error, error,
    ]);
  });
});

describe("buildJitTrade", () => {
  it("uses the observed balance and the wire expiry for the JIT order and its commit", () => {
    const limit = { buyAmount: 25n, validTo: Number(blockTimestamp) + terms.auctionDuration + 120 };
    const order = buildOrder({
      sellToken, resourceToken: buyToken, resourceRecipient: receiver, sellAmount: 100n,
      currentMinimumBuyAmount: terms.currentMinimumBuyAmount, appData, ...limit,
    });
    expect(buildJitTrade(terms, limit)).toEqual({
      jitOrder: toSolverJitOrder(silo, order),
      executedAmount: "100",
      preInteraction: buildCommitInteraction(silo, order),
    });
  });

  describe.each([
    ["flat", { ...terms, auctionDuration: 0, currentMinimumBuyAmount: terms.minimumBuyAmount }],
    ["descending", terms],
  ] as const)("%s auction", (_, observed) => {
    const earliest = Number(blockTimestamp) + observed.auctionDuration;
    const buyAmount = observed.currentMinimumBuyAmount;

    it.each([0, 300])("accepts an execution deadline %s seconds after the block", (seconds) => {
      const validTo = earliest + seconds;
      expect(buildJitTrade(observed, { buyAmount, validTo }).jitOrder.validTo).toBe(validTo);
    });

    it.each([-1, 301, 0.5])("rejects an execution deadline offset of %s seconds", (seconds) => {
      expect(() => buildJitTrade(observed, { buyAmount, validTo: earliest + seconds })).toThrow();
    });
  });

  it("rejects a wire expiry that exceeds uint32 even if the execution deadline is valid", () => {
    const validTo = 0x1_0000_0000;
    const nearRollover = { ...terms, blockTimestamp: BigInt(validTo - terms.auctionDuration) };
    expect(() => buildJitTrade(nearRollover, { buyAmount: 25n, validTo })).toThrow();
  });

  it("rejects a buy amount at the static floor but below the live minimum", () => {
    const validTo = Number(blockTimestamp) + terms.auctionDuration;
    expect(() => buildJitTrade(terms, { buyAmount: terms.minimumBuyAmount, validTo })).toThrow();
  });
});
