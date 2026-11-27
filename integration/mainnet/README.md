# Mainnet fork tests

These tests execute Silo orders through Ethereum's deployed CoW Settlement, HooksTrampoline, and Vault Relayer with real USDC and WETH code. Silo and its funding adapter are deployed only on the local fork. No transaction is broadcast. No private key is needed.

## Run

Install the root project dependencies and Foundry, then run from the repository root:

```sh
pnpm test:mainnet
```

Override the endpoint or block explicitly:

```sh
MAINNET_RPC_URL=https://eth.drpc.org MAINNET_FORK_BLOCK=26399049 pnpm test:mainnet
```

Run one test with a full trace:

```sh
pnpm test:mainnet --match-test testExternalTreasuryFundsAndSettlesOrder -vvvv
```

The `mainnet` Foundry profile uses `integration/mainnet` as its test root. The default profile and `pnpm test` remain offline. Fork tests run with one thread to reduce RPC load. RPC errors and invalid fixtures fail the tests; the suite does not skip them or fall back to the latest block. A different block can require new solver or token-holder fixtures.

## Coverage

- An external treasury funds an empty Silo and completes a trade.
- A nondefault 600,000-gas hook completes a trade.
- A gas-limit change rejects a stale appData document and rolls back funding. Restoring the prior limit permits the same order again.
- An unrelated account can trigger funding into the fixed Silo before a standard settlement.
- Settlement can call `prepare` directly without the trampoline.
- Existing Silo inventory combines with allowance-limited treasury funding. Unapproved inventory stays at the source.
- Settlement buffers fund a trade within a fixed approval budget. An authorized solver grants that approval through an empty settlement.
- A failed adapter call still permits a prefunded trade.
- An incorrect expected balance rolls back funding.
- An order below the minimum fails real ERC1271 validation and rolls back funding.
- A late WETH payment failure rolls back funding, token transfers, allowances, fill state, and the transient preparation.

The standard trade path calls `HooksTrampoline.execute` from Settlement with a `Silo.prepare(USDC)` pre-hook at the Silo's current `hookGasLimit`, initially 500,000. `prepare` is permissionless, and Silo has no trampoline configuration. The Silo checks the exact canonical appData hash and the prepared amount during real ERC1271 validation. The trampoline address comes from the upstream [deployment artifact](https://github.com/cowprotocol/hooks-trampoline/blob/main/cannon/deploy.json).

Successful trades check token movement, preserved Settlement buffers, and Settlement's recorded filled amount. Rollback tests compare balances, allowances, fill state, and preparation before and after the failed call.

## Fixtures and limits

The fixture checks chain ID, deployed token, Settlement, and HooksTrampoline code, the trampoline's Settlement binding, the authenticator and Vault Relayer addresses, and the solver's actual authorization. It does not replace deployed code, change authentication, or write token storage. It seeds USDC with transfers from a real holder. It gives the solver ETH on the local fork and calls WETH's real `deposit` method.

| Contract or account | Mainnet address |
| --- | --- |
| Settlement | `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` |
| HooksTrampoline | `0x60Bf78233f48eC42eE3F101b9a05eC7878728006` |
| Vault Relayer | `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` |
| Authenticator | `0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE` |
| Authorized solver | `0x5ed864e8f37DCB4f79c5172A815D1B3a9147eaaB` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC fixture holder | `0x55FE002aefF02F77364de339a1292923A15844B8` |

All caller impersonation occurs only on the local fork. The solver supplies test liquidity directly: Settlement sends the sold USDC to the solver, then pulls the solver's WETH before paying the resource recipient. The tests do not submit orders to the CoW Order Book, use an AMM route, check market prices, enter a live auction, or validate solution scoring. They do not grant permission to use these accounts on mainnet.
