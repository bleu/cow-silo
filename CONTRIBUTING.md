# Contributing

Use focused changes. Add a test for each behavior change.

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile
forge fmt --check
forge test
pnpm --filter @cow-silo/sdk typecheck
pnpm --filter @cow-silo/sdk test
pnpm --filter @cow-silo/docs build
```

Document security assumptions. Use short sentences and active voice in user documentation.
