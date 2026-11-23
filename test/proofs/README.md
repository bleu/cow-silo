# Auction clock proof

The tests deploy the production `Silo` contract and the pinned CoW Settlement creation bytecode on a local chain. They use mock ERC-20 tokens and a test solver. No RPC, driver, or mainnet deployment is required.

With the git submodules and Solidity 0.8.26 installed, run this command from the repository root:

```sh
forge test --offline --match-path test/proofs/AuctionClock.t.sol -vv
```

The Silo starts at 150 units of the resource token and reaches its floor of 100 after two hours. The tests advance to the floor before submitting orders. Settlement calls `Silo.commit(order)` before each trade. The commitment expires at the end of the transaction. Settlement's full-fill record determines whether the clock restarts for the sold token.

- A commit without a trade leaves the token at 100. The same order can still be filled.
- After a full sale at 100, new inventory of the same token requires 150 in the same block. A second token can still sell at 100.
- Committing an already filled order fails. Two new commits without fills, 30 and 40 minutes after a confirmed sale, leave its clock unchanged. At one hour, 124 is rejected and 125 fills.
- Ten minutes after a sale, the required output is `150 - floor(50 * 10 / 120) = 146`.
- If Settlement cannot pay the recipient, the trade rolls back. The test checks that the fill record is zero and the token can still sell at 100.
- The Silo accepts the order at its execution deadline. One second later, validation and commit both fail, even though CoW `validTo` is still in the future.
- After `validTo`, the test calls Settlement's `freeFilledAmountStorage`, checks that the fill record is zero, and sells new inventory at the floor of 100.

The default test order has a five-minute Silo execution window. Its CoW `validTo` is the execution deadline plus two hours. This keeps the fill record available until the token reaches its floor again. These tests do not check whether a driver accepts that wire lifetime.
