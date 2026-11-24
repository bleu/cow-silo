# CoW offline integration profile

This profile uses the [CoW Protocol Offline Playground](https://github.com/cowdao-grants/offline-mode). The playground runs a local chain and the main CoW services. It includes Settlement, Vault Relayer, orderbook, autopilot, driver, baseline solver, test tokens, and test liquidity.

The helper pins upstream commit `233c400c446c0d3c6f7a898892332818296b6053`. It stores the checkout in `.cache/cow-offline`.

## Start

Requirements:

- Docker 23 or later.
- Docker Compose.
- Node.js 18 or later.
- Foundry.

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

This profile starts the dependency stack. Foundry unit tests remain the default CI path. A complete Silo settlement scenario is roadmap work because the local driver must also recognize the Silo as a surplus-capturing JIT owner and a solver must submit the Silo JIT trade.

Use the `cowprotocol/services` playground when a test needs the newest production service code. The grant playground is useful for isolated and repeatable local work.
