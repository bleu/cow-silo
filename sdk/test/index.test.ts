import { decodeAbiParameters, getAddress, parseAbi, parseAbiParameters, size } from "viem";
import { describe, expect, it } from "vitest";

import {
  BALANCE_ERC20,
  buildCommitInteraction,
  buildCommitInteractions,
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

  it("exposes auction settings and the live minimum for a sell token", () => {
    const getters = parseAbi([
      "function initialBuyAmount() view returns (uint256)",
      "function minimumBuyAmount() view returns (uint256)",
      "function auctionDuration() view returns (uint32)",
      "function currentMinimumBuyAmount(address sellToken) view returns (uint256)",
    ]);
    for (const getter of getters) expect(siloAbi).toContainEqual(getter);
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

  it("creates the CoW solver wire format", () => {
    const { validTo } = buildOrderDeadlines({ blockTimestamp: 1000, executionWindow: 90, auctionDuration: 3600 });
    const jitOrder = order(validTo);
    expect(toSolverJitOrder(silo, jitOrder)).toEqual({
      sellToken,
      buyToken: resourceToken,
      receiver,
      sellAmount: "100",
      buyAmount: "25",
      validTo: 4690,
      appData,
      kind: "sell",
      partiallyFillable: false,
      sellTokenBalance: "erc20",
      buyTokenBalance: "erc20",
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
