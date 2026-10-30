import { decodeAbiParameters, getAddress, parseAbiParameters, size } from "viem";
import { describe, expect, it } from "vitest";

import {
  BALANCE_ERC20,
  buildCommitInteraction,
  buildOrder,
  encodeOrderPayload,
  encodeSolverSignature,
  hashOrder,
  KIND_SELL,
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
    validTo: 1_900_000_000,
    appData,
  });
}

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

  it("uses the same hash in the JIT order and commit interaction", () => {
    const digest = hashOrder(order(), domainSeparator);
    const interaction = buildCommitInteraction(silo, order(), domainSeparator);
    expect(digest).toMatch(/^0x[0-9a-f]{64}$/);
    expect(interaction.target).toBe(silo);
    expect(interaction.callData).toContain(digest.slice(2));
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
        validTo: 1,
        appData,
      }),
    ).toThrow("sellToken must differ");
  });
});
