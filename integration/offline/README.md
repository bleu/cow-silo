# CoW offline integration profile

This profile uses the [CoW Protocol Offline Playground](https://github.com/cowdao-grants/offline-mode). The playground runs a local chain and the main CoW services. It includes Settlement, Vault Relayer, orderbook, autopilot, driver, baseline solver, test tokens, and test liquidity.

The helper pins upstream commit `233c400c446c0d3c6f7a898892332818296b6053`. It stores the checkout in `.cache/cow-offline`.

## Start

Requirements for running the commands from the repository root:

- Git and Foundry.
- Docker 23 or later with Docker Compose.
- Node.js 24 or later with npm.

```sh
./integration/offline/manage.sh bootstrap
./integration/offline/manage.sh up
./integration/offline/manage.sh status
```

The first build can take several minutes.

## Stop

```sh
./integration/offline/manage.sh down
```

## Current scope

This profile starts the local services. It does not configure the driver to recognize a Silo as a surplus-capturing JIT owner or submit a Silo trade. Before using a driver, check that it accepts the chosen CoW `validTo`: the Silo execution deadline plus the effective `auctionDuration`. The Silo execution window is at most five minutes even when `validTo` is later.

For a contract test without the service stack, run the [local auction clock proof](../../test/proofs/README.md). It exercises the production Silo against pinned Settlement bytecode.
