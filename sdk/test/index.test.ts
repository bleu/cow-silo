import { decodeAbiParameters, decodeFunctionData, getAddress, keccak256, parseAbiParameters, size, stringToHex } from "viem";
import { describe, expect, it } from "vitest";

import {
  BALANCE_ERC20,
  buildAppData,
  buildPreparationHook,
  buildOrder,
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

function order() {
  return buildOrder({
    sellToken,
    resourceToken,
    resourceRecipient: receiver,
    sellAmount: 100n,
    buyAmount: 25n,
    minimumBuyAmount: 10n,
    validTo: 1_900_000_000,
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
    const result = buildAppData(vector.silo, vector.sellToken);
    expect(result).toEqual({
      document: vector.document,
      hash: vector.hash,
      hook: { target: vector.silo, callData: vector.callData, gasLimit: "500000" },
    });
    expect(size(result.hook.target)).toBe(20);
    expect(size(result.hook.callData)).toBe(36);
    expect(keccak256(stringToHex(vector.document))).toBe(vector.hash);
  });

  it("normalizes checksummed addresses to lowercase", () => {
    const { silo, sellToken } = vectors[0];
    expect(buildAppData(getAddress(silo), getAddress(sellToken))).toEqual(buildAppData(silo, sellToken));
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

  it("hashes the order with its domain separator", () => {
    expect(hashOrder(order(), domainSeparator)).toMatch(/^0x[0-9a-f]{64}$/);
    expect(hashOrder(order(), domainSeparator)).not.toBe(hashOrder({ ...order(), buyAmount: 26n }, domainSeparator));
  });

  it("builds a token-scoped preparation hook", () => {
    const hook = buildPreparationHook(silo, sellToken);
    expect(hook.target).toBe(silo);
    expect(hook.gasLimit).toBe("500000");
    expect(decodeFunctionData({ abi: siloAbi, data: hook.callData })).toEqual({
      functionName: "prepare", args: [sellToken],
    });
  });

  it("creates the CoW solver wire format", () => {
    expect(toSolverJitOrder(silo, order())).toMatchObject({
      sellAmount: "100",
      buyAmount: "25",
      kind: "sell",
      signingScheme: "eip1271",
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
        minimumBuyAmount: 1n,
        validTo: 1,
        appData,
      }),
    ).toThrow("sellToken must differ");
  });

  it("rejects a buy amount below the configured minimum", () => {
    expect(() =>
      buildOrder({
        sellToken,
        resourceToken,
        resourceRecipient: receiver,
        sellAmount: 100n,
        buyAmount: 9n,
        minimumBuyAmount: 10n,
        validTo: 1,
        appData,
      }),
    ).toThrow("buyAmount must be at least minimumBuyAmount");
  });
});
