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
  appData, domainSeparator, blockNumber, blockTimestamp,
} as const;

const readAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function minimumBuyAmount() view returns (uint256)",
  "function appData() view returns (bytes32)",
  "function domainSeparator() view returns (bytes32)",
]);

type RpcRequest =
  | { method: "eth_getBlockByNumber"; params: [Hex | "latest", boolean] }
  | { method: "eth_call"; params: [{ data: Hex }, Hex | "latest"] };

type ReadValues = Partial<Record<Address, bigint | "revert">>;

function testChain({ balances = {}, floors = {} }: { balances?: ReadValues; floors?: ReadValues } = {}) {
  const state = { latest: blockNumber };
  const blocks: string[] = [];
  const reads: { block: string; target: Address; getter: string; owner?: Address }[] = [];
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
          reads.push({ block, target, getter: functionName, owner: args?.[0] });
          const number = block === "latest" ? state.latest : BigInt(block);
          const values = {
            resourceToken: buyToken,
            resourceRecipient: receiver,
            minimumBuyAmount: floors[target] ?? (number === blockNumber ? 10n : 14n),
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
  it("reads fresh inventory and the current floor, and can read an earlier block", async () => {
    const { client, state, reads, blocks } = testChain();
    expect(await readOrderTerms(client, pair)).toEqual(terms);

    state.latest += 1n;
    expect(await readOrderTerms(client, pair)).toEqual({
      ...terms,
      sellAmount: 73n,
      minimumBuyAmount: 14n,
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
  it("reads each Silo configuration and pair balance once, even for repeated pairs", async () => {
    const { client, reads, blocks, state } = testChain({ balances: { [otherToken]: 35n }, floors: { [otherSilo]: 8n } });
    state.latest += 1n;
    const pairs = [{ silo, sellToken: otherToken }, { silo: otherSilo, sellToken }, pair, pair] as const;
    const result = await readOrderTermsBatch(client, { pairs, blockNumber });
    expect(result).toEqual([
      { status: "available", terms: { ...terms, sellToken: otherToken, sellAmount: 35n } },
      { status: "available", terms: { ...terms, silo: otherSilo, minimumBuyAmount: 8n } },
      { status: "available", terms },
      { status: "available", terms },
    ]);
    expect(blocks).toEqual([numberToHex(blockNumber)]);
    expect(new Set(reads.map(({ block }) => block))).toEqual(new Set([numberToHex(blockNumber)]));
    for (const address of [silo, otherSilo]) {
      expect(reads.filter(({ target }) => target === address).map(({ getter }) => getter).sort()).toEqual([
        "appData", "domainSeparator", "minimumBuyAmount", "resourceRecipient", "resourceToken",
      ]);
    }
    const balances = reads.filter(({ getter }) => getter === "balanceOf").map(({ target, owner }) => [target, owner]);
    expect(balances).toHaveLength(3);
    expect(balances).toEqual(expect.arrayContaining([[otherToken, silo], [sellToken, otherSilo], [sellToken, silo]]));
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
  it("produces the same JIT order and commit pre-interaction as the existing builders", () => {
    const limit = { buyAmount: 25n, validTo: Number(blockTimestamp) + 120 };
    const order = buildOrder({
      sellToken, resourceToken: buyToken, resourceRecipient: receiver, sellAmount: 100n,
      minimumBuyAmount: 10n, appData, ...limit,
    });
    expect(buildJitTrade(terms, limit)).toEqual({
      jitOrder: toSolverJitOrder(silo, order),
      executedAmount: "100",
      preInteraction: buildCommitInteraction(silo, order, domainSeparator),
    });
  });

  it("accepts both ends of the five-minute validity window for the observed block", () => {
    for (const seconds of [0, 300]) {
      const validTo = Number(blockTimestamp) + seconds;
      expect(buildJitTrade(terms, { buyAmount: 10n, validTo }).jitOrder.validTo).toBe(validTo);
    }
  });

  it.each([-1, 301, 0.5])("rejects an expiry offset of %s seconds", (seconds) => {
    expect(() => buildJitTrade(terms, { buyAmount: 10n, validTo: Number(blockTimestamp) + seconds })).toThrow();
  });

  it("rejects an expiry that fits the time window but exceeds uint32", () => {
    const nearRollover = { ...terms, blockTimestamp: 0xffff_fffen };
    expect(() => buildJitTrade(nearRollover, { buyAmount: 10n, validTo: 0x1_0000_0000 })).toThrow();
  });

  it("rejects a buy amount below the observed floor", () => {
    expect(() => buildJitTrade(terms, { buyAmount: 9n, validTo: Number(blockTimestamp) })).toThrow();
  });
});
