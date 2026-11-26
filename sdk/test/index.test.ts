import { decodeAbiParameters, decodeFunctionData, getAddress, keccak256, maxUint256, parseAbiParameters, size, stringToHex } from "viem";
import { describe, expect, it } from "vitest";

import {
  BALANCE_ERC20,
  buildAppData,
  buildCommitInteraction,
  buildCommitInteractions,
  buildPreparationHook,
  buildOrder,
  buildOrderDeadlines,
  encodeOrderPayload,
  encodeSolverSignature,
  hashOrder,
  KIND_SELL,
  siloAbi,
  toSolverJitOrder,
} from "../src/index.js";

const silo = getAddress("0x1111111111111111111111111111111111111111");
const sellToken = getAddress("0x2222222222222222222222222222222222222222");
const resourceToken = getAddress("0x3333333333333333333333333333333333333333");
const receiver = getAddress("0x4444444444444444444444444444444444444444");
const appData = `0x${"55".repeat(32)}` as const;
const domainSeparator = `0x${"66".repeat(32)}` as const;

function order(validTo = 1_900_000_000) {
  return buildOrder({
    sellToken,
    resourceToken,
    resourceRecipient: receiver,
    sellAmount: 100n,
    buyAmount: 25n,
    currentMinimumBuyAmount: 10n,
    validTo,
    appData,
  });
}

describe("canonical appData", () => {
  const vectors = [
    {
      silo: "0x00000000000000000000000000000000000000ab",
      sellToken: "0x00000000000000000000000000000000000000cd",
      callData: "0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd",
      document: '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x00000000000000000000000000000000000000ab","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd","gasLimit":"500000"}]}}}',
      hash: "0xee2957f4feeb0e935ca682ff1afe936e7bdf5a06392ad586173f4116a9fcea76",
    },
    {
      silo: "0x00000000000000000000000000000000000000ab",
      sellToken: "0x00000000000000000000000000000000000000ef",
      callData: "0xbabed18a00000000000000000000000000000000000000000000000000000000000000ef",
      document: '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x00000000000000000000000000000000000000ab","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000ef","gasLimit":"500000"}]}}}',
      hash: "0x8ba2f9a5d77f6d1be2766857a0f1e2bfacb71269901694d10df84815e25778c2",
    },
    {
      silo: "0x0000000000000000000000000000000000000012",
      sellToken: "0x00000000000000000000000000000000000000cd",
      callData: "0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd",
      document: '{"version":"1.3.0","metadata":{"hooks":{"pre":[{"target":"0x0000000000000000000000000000000000000012","callData":"0xbabed18a00000000000000000000000000000000000000000000000000000000000000cd","gasLimit":"500000"}]}}}',
      hash: "0x7f64d7a41a78a56583d060d25b6c7d3bffa38035ce56c83bc69dd074c002de22",
    },
  ] as const;

  it.each(vectors)("matches exact JSON, calldata, and hash for $silo / $sellToken", (vector) => {
    const result = buildAppData(vector.silo, vector.sellToken, 500_000n);
    expect(result).toEqual({
      document: vector.document,
      hash: vector.hash,
      hook: { target: vector.silo, callData: vector.callData, gasLimit: "500000" },
    });
    expect(size(result.hook.target)).toBe(20);
    expect(size(result.hook.callData)).toBe(36);
    expect(keccak256(stringToHex(vector.document))).toBe(vector.hash);
  });

  it.each([
    { hookGasLimit: 600_000n, decimal: "600000", hash: "0xbc735adaef4c18f438c2d6baeefc621df188217f2bb6b606c9a2e4003ecd9436" },
    {
      hookGasLimit: maxUint256,
      decimal: "115792089237316195423570985008687907853269984665640564039457584007913129639935",
      hash: "0x16c15ab419985a293ad2615b457d711f0ec01fbeaae6ddbac7dce3b15633feb5",
    },
  ])("matches the variable gas vector for $decimal", ({ hookGasLimit, decimal, hash }) => {
    const vector = vectors[0];
    const result = buildAppData(vector.silo, vector.sellToken, hookGasLimit);
    expect(result).toEqual({
      document: vector.document.replace('"500000"', `"${decimal}"`),
      hash,
      hook: { target: vector.silo, callData: vector.callData, gasLimit: decimal },
    });
    expect(result.hash).not.toBe(vector.hash);
    expect(buildPreparationHook(vector.silo, vector.sellToken, hookGasLimit)).toEqual(result.hook);
  });

  it("accepts the smallest nonzero gas limit", () => {
    expect(buildPreparationHook(silo, sellToken, 1n).gasLimit).toBe("1");
  });

  it.each([0n, -1n, maxUint256 + 1n])("rejects an invalid hook gas limit of %s", (hookGasLimit) => {
    expect(() => buildPreparationHook(silo, sellToken, hookGasLimit)).toThrow("hookGasLimit must be a nonzero uint256");
    expect(() => buildAppData(silo, sellToken, hookGasLimit)).toThrow("hookGasLimit must be a nonzero uint256");
  });

  it("normalizes checksummed addresses to lowercase", () => {
    const { silo, sellToken } = vectors[0];
    expect(buildAppData(getAddress(silo), getAddress(sellToken), 500_000n)).toEqual(buildAppData(silo, sellToken, 500_000n));
  });

  it("binds the hash to every JSON byte", () => {
    const { document, hash } = vectors[0];
    const parsed = JSON.parse(document);
    const hook = parsed.metadata.hooks.pre[0];
    const changed = [
      document + "\n",
      JSON.stringify(parsed, null, 2),
      document.replace('"version":"1.3.0"', '"version":"1.3.1"'),
      document.replace(hook.target, vectors[2].silo),
      document.replace(hook.callData, vectors[1].callData),
      document.replace('"500000"', '"500001"'),
      JSON.stringify({ ...parsed, metadata: { ...parsed.metadata, extra: true } }),
      JSON.stringify({ ...parsed, metadata: { hooks: { pre: [hook, hook] } } }),
    ];
    for (const bytes of changed) expect(keccak256(stringToHex(bytes))).not.toBe(hash);
  });
});

describe("Silo SDK", () => {
  it("separates the execution deadline from the wire validTo", () => {
    expect(buildOrderDeadlines({ blockTimestamp: 1_900_000_000, executionWindow: 300, auctionDuration: 3600 })).toEqual({
      executionDeadline: 1_900_000_300,
      validTo: 1_900_003_900,
    });
  });
  it("uses the execution deadline unchanged for a fixed-price Silo", () => {
    expect(buildOrderDeadlines({ blockTimestamp: 0xffff_ffff, executionWindow: 0, auctionDuration: 0 })).toEqual({
      executionDeadline: 0xffff_ffff,
      validTo: 0xffff_ffff,
    });
  });

  it("requires an execution window in whole seconds between 0 and 300", () => {
    for (const executionWindow of [301, -1, 0.5, NaN, Infinity, 2 ** 53]) {
      expect(() => buildOrderDeadlines({ blockTimestamp: 1000, executionWindow, auctionDuration: 0 })).toThrow("executionWindow");
    }
  });

  it("rejects deadline calculations outside whole uint32 seconds", () => {
    for (const [blockTimestamp, executionWindow, auctionDuration] of [
      [-1, 1, 0],
      [1.5, 0, 0],
      [NaN, 0, 0],
      [2 ** 53, 0, 0],
      [1000, 0, -1],
      [1000, 0, 0.5],
      [1000, 0, Infinity],
      [0, 0, 2 ** 32],
      [0xffff_ffff, 1, 0],
      [0xffff_ffff, 0, 1],
    ] as const) {
      expect(() => buildOrderDeadlines({ blockTimestamp, executionWindow, auctionDuration })).toThrow("uint32");
    }
  });

  it("builds the canonical immutable fields", () => {
    expect(order()).toMatchObject({
      buyToken: resourceToken,
      receiver,
      feeAmount: 0n,
      kind: KIND_SELL,
      partiallyFillable: false,
      sellTokenBalance: BALANCE_ERC20,
      buyTokenBalance: BALANCE_ERC20,
    });
  });

  it("encodes a payload that follows the Solidity order tuple", () => {
    const params = parseAbiParameters(
      "(address sellToken, address buyToken, address receiver, uint256 sellAmount, uint256 buyAmount, uint32 validTo, bytes32 appData, uint256 feeAmount, bytes32 kind, bool partiallyFillable, bytes32 sellTokenBalance, bytes32 buyTokenBalance)",
    );
    const [decoded] = decodeAbiParameters(params, encodeOrderPayload(order()));
    expect(decoded.sellAmount).toBe(100n);
    expect(decoded.buyAmount).toBe(25n);
  });

  it("prepends the 20-byte EIP-1271 owner for the solver API", () => {
    const rawPayload = encodeOrderPayload(order());
    const signature = encodeSolverSignature(silo, order());
    expect(signature.startsWith(silo.toLowerCase())).toBe(true);
    expect(size(signature)).toBe(20 + size(rawPayload));
  });

  it("retains the native GPv2 EIP-712 digest", () => {
    expect(hashOrder(order(), domainSeparator)).toBe("0x2743026369fc008bfc1b759b30bdc428f1516a769e23d728e3757d97bcd4e70d");
  });

  it("encodes commit with the full GPv2 order", () => {
    const interaction = buildCommitInteraction(silo, order());
    expect(interaction).toEqual({
      target: silo,
      value: "0",
      callData: `0x23c6ff72${encodeOrderPayload(order()).slice(2)}`,
    });
  });

  it("builds independent commit interactions for distinct sell tokens", () => {
    const first = order();
    const second = { ...first, sellToken: getAddress("0x7777777777777777777777777777777777777777") };
    expect(buildCommitInteractions(silo, [first, second])).toEqual([
      buildCommitInteraction(silo, first),
      buildCommitInteraction(silo, second),
    ]);
  });

  it("rejects a repeated sell token regardless of address case", () => {
    const lowerCase = "0x5aeda56215b167893e80b4fe645ba6d5bab767de";
    const first = { ...order(), sellToken: getAddress(lowerCase) };
    const second = { ...order(), sellToken: lowerCase, buyAmount: 50n } as const;
    expect(() => buildCommitInteractions(silo, [first, second])).toThrow("duplicate sellToken");
  });

  it("rejects a wire validTo that cannot fit in a GPv2 order", () => {
    for (const validTo of [-1, 0.5, 2 ** 32, 2 ** 53, NaN, Infinity]) {
      expect(() => order(validTo)).toThrow("validTo");
    }
  });

  it("hashes the order with its domain separator", () => {
    expect(hashOrder(order(), domainSeparator)).toMatch(/^0x[0-9a-f]{64}$/);
    expect(hashOrder(order(), domainSeparator)).not.toBe(hashOrder({ ...order(), buyAmount: 26n }, domainSeparator));
  });

  it("builds a token-scoped preparation hook", () => {
    const hook = buildPreparationHook(silo, sellToken, 500_000n);
    expect(hook.target).toBe(silo);
    expect(hook.gasLimit).toBe("500000");
    expect(decodeFunctionData({ abi: siloAbi, data: hook.callData })).toEqual({
      functionName: "prepare", args: [sellToken],
    });
  });

  it("creates the CoW solver wire format", () => {
    const { validTo } = buildOrderDeadlines({ blockTimestamp: 1000, executionWindow: 90, auctionDuration: 3600 });
    const jitOrder = order(validTo);
    expect(toSolverJitOrder(silo, jitOrder)).toMatchObject({
      sellAmount: "100",
      buyAmount: "25",
      validTo: 4690,
      kind: "sell",
      signingScheme: "eip1271",
      signature: `${silo}${encodeOrderPayload(jitOrder).slice(2)}`,
    });
  });

  it("rejects invalid inputs early", () => {
    expect(() =>
      buildOrder({
        sellToken: resourceToken,
        resourceToken,
        resourceRecipient: receiver,
        sellAmount: 1n,
        buyAmount: 1n,
        currentMinimumBuyAmount: 1n,
        validTo: 1,
        appData,
      }),
    ).toThrow("sellToken must differ");
  });

  it("rejects the old global floor when the live minimum is missing", () => {
    const legacyInput = {
      sellToken,
      resourceToken,
      resourceRecipient: receiver,
      sellAmount: 100n,
      buyAmount: 25n,
      minimumBuyAmount: 10n,
      validTo: 1,
      appData,
    };
    // @ts-expect-error JavaScript callers can still pass the old input.
    expect(() => buildOrder(legacyInput)).toThrow("currentMinimumBuyAmount");
  });

  it("rejects a buy amount below the sell token's live minimum", () => {
    expect(() =>
      buildOrder({
        sellToken,
        resourceToken,
        resourceRecipient: receiver,
        sellAmount: 100n,
        buyAmount: 9n,
        currentMinimumBuyAmount: 10n,
        validTo: 1,
        appData,
      }),
    ).toThrow("buyAmount must be at least currentMinimumBuyAmount");
  });
});
