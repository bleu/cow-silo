import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  maxUint256,
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
  buildAppData,
  buildPreparationHook,
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
const hookGasLimit = 500_000n;
const appData = buildAppData(silo, sellToken, hookGasLimit).hash;
const domainSeparator = `0x${"66".repeat(32)}` as const;
const blockNumber = 20_000_000n;
const blockTimestamp = 1_900_000_000n;
const otherSilo = "0x7777777777777777777777777777777777777777";
const otherToken = "0x8888888888888888888888888888888888888888";
const brokenToken = "0x9999999999999999999999999999999999999999";
const pair = { silo, sellToken } as const;
const terms = {
  ...pair, buyToken, receiver, sellAmount: 100n, minimumBuyAmount: 10n,
  appData, hookGasLimit, domainSeparator, blockNumber, blockTimestamp,
} as const;

const readAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function resourceToken() view returns (address)",
  "function resourceRecipient() view returns (address)",
  "function minimumBuyAmount() view returns (uint256)",
  "function hookGasLimit() view returns (uint256)",
  "function appData(address) view returns (bytes32)",
  "function domainSeparator() view returns (bytes32)",
]);

type RpcRequest =
  | { method: "eth_getBlockByNumber"; params: [Hex | "latest", boolean] }
  | { method: "eth_call"; params: [{ data: Hex }, Hex | "latest"] };

type ReadValues = Partial<Record<Address, bigint | "revert">>;

function testChain({ balances = {}, floors = {}, gasLimits = {} }: {
  balances?: ReadValues;
  floors?: ReadValues;
  gasLimits?: ReadValues;
} = {}) {
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
          const gasLimit = gasLimits[target] ?? (number === blockNumber ? hookGasLimit : 600_000n);
          const values = {
            resourceToken: buyToken,
            resourceRecipient: receiver,
            minimumBuyAmount: floors[target] ?? (number === blockNumber ? 10n : 14n),
            hookGasLimit: gasLimit,
            appData: buildAppData(target, args?.[0] ?? sellToken, gasLimit === "revert" ? hookGasLimit : gasLimit).hash,
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
  it("reads inventory, floor, hook gas, and appData at the same block", async () => {
    const { client, state, reads, blocks } = testChain();
    expect(await readOrderTerms(client, pair)).toEqual(terms);

    state.latest += 1n;
    expect(await readOrderTerms(client, pair)).toEqual({
      ...terms,
      sellAmount: 73n,
      minimumBuyAmount: 14n,
      hookGasLimit: 600_000n,
      appData: buildAppData(silo, sellToken, 600_000n).hash,
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
    const { client, reads, blocks, state } = testChain({
      balances: { [otherToken]: 35n }, floors: { [otherSilo]: 8n }, gasLimits: { [otherSilo]: maxUint256 },
    });
    state.latest += 1n;
    const pairs = [{ silo, sellToken: otherToken }, { silo: otherSilo, sellToken }, pair, pair] as const;
    const result = await readOrderTermsBatch(client, { pairs, blockNumber });
    expect(result).toEqual([
      { status: "available", terms: { ...terms, sellToken: otherToken, sellAmount: 35n, appData: buildAppData(silo, otherToken, hookGasLimit).hash } },
      { status: "available", terms: {
        ...terms, silo: otherSilo, minimumBuyAmount: 8n, hookGasLimit: maxUint256,
        appData: buildAppData(otherSilo, sellToken, maxUint256).hash,
      } },
      { status: "available", terms },
      { status: "available", terms },
    ]);
    expect(blocks).toEqual([numberToHex(blockNumber)]);
    expect(new Set(reads.map(({ block }) => block))).toEqual(new Set([numberToHex(blockNumber)]));
    for (const address of [silo, otherSilo]) {
      expect(reads.filter(({ target, getter }) => target === address && getter !== "appData").map(({ getter }) => getter).sort()).toEqual([
        "domainSeparator", "hookGasLimit", "minimumBuyAmount", "resourceRecipient", "resourceToken",
      ]);
    }
    const appDataReads = reads.filter(({ getter }) => getter === "appData").map(({ target, owner }) => [target, owner]);
    expect(appDataReads).toHaveLength(3);
    expect(appDataReads).toEqual(expect.arrayContaining([[silo, otherToken], [otherSilo, sellToken], [silo, sellToken]]));
    const balances = reads.filter(({ getter }) => getter === "balanceOf").map(({ target, owner }) => [target, owner]);
    expect(balances).toHaveLength(3);
    expect(balances).toEqual(expect.arrayContaining([[otherToken, silo], [sellToken, otherSilo], [sellToken, silo]]));
  });

  it("keeps a hook gas read failure local to its Silo", async () => {
    const { client } = testChain({ gasLimits: { [otherSilo]: "revert" } });
    await expect(readOrderTerms(client, { silo: otherSilo, sellToken })).rejects.toThrow();
    expect(await readOrderTermsBatch(client, { pairs: [{ silo: otherSilo, sellToken }, pair] })).toEqual([
      { status: "error", error: expect.any(Error) },
      { status: "available", terms },
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
  it("returns the publication document and its preparation hook with the JIT order", () => {
    const limit = { buyAmount: 25n, validTo: Number(blockTimestamp) + 120 };
    const order = buildOrder({
      sellToken, resourceToken: buyToken, resourceRecipient: receiver, sellAmount: 100n,
      minimumBuyAmount: 10n, appData, ...limit,
    });
    expect(buildJitTrade(terms, limit)).toEqual({
      jitOrder: toSolverJitOrder(silo, order),
      executedAmount: "100",
      appDataDocument: buildAppData(silo, sellToken, hookGasLimit).document,
      preparationHook: buildPreparationHook(silo, sellToken, hookGasLimit),
    });
  });

  it.each([600_000n, maxUint256])("uses the observed hook gas limit of %s", (hookGasLimit) => {
    const canonical = buildAppData(silo, sellToken, hookGasLimit);
    const result = buildJitTrade({ ...terms, hookGasLimit, appData: canonical.hash }, {
      buyAmount: 10n, validTo: Number(blockTimestamp),
    });
    expect(result.appDataDocument).toBe(canonical.document);
    expect(result.preparationHook.gasLimit).toBe(hookGasLimit.toString());
    expect(result.jitOrder.appData).toBe(canonical.hash);
  });

  it("rejects the old document after the observed gas limit changes", () => {
    expect(() => buildJitTrade({ ...terms, hookGasLimit: 600_000n }, {
      buyAmount: 10n, validTo: Number(blockTimestamp),
    })).toThrow("appData must match");
  });

  it.each([0n, -1n, maxUint256 + 1n])("rejects invalid observed hook gas of %s", (hookGasLimit) => {
    expect(() => buildJitTrade({ ...terms, hookGasLimit }, {
      buyAmount: 10n, validTo: Number(blockTimestamp),
    })).toThrow("hookGasLimit must be a nonzero uint256");
  });

  it("rejects an appData hash for a different pair", () => {
    const wrongTerms = { ...terms, appData: buildAppData(silo, otherToken, hookGasLimit).hash };
    expect(() => buildJitTrade(wrongTerms, { buyAmount: 10n, validTo: Number(blockTimestamp) })).toThrow("appData must match");
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
