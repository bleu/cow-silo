# Contributing

Use focused changes. Add a test for each behavior change.

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile
pnpm format:check
pnpm test
pnpm build
```

Document security assumptions. Use short sentences and active voice in user documentation.
