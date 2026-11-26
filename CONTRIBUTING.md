# Contributing

Use focused changes. Add a test for each behavior change.

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile
forge fmt --check
forge test
TEST_ISOLATED=true forge test --isolate --match-test testPreparationExpiresAfterTransaction
TEST_ISOLATED=true forge test --isolate --match-path test/proofs/AuctionClock.t.sol
pnpm --filter @cow-silo/sdk typecheck
pnpm --filter @cow-silo/sdk test
pnpm --filter @cow-silo/docs build
```

Document security assumptions. Use short sentences and active voice in user documentation.
