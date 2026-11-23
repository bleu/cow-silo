# Security

CoW Silo is unaudited. Do not use this version with production funds.

Send a private report to `security@bleu.fi`. Include the affected commit, the impact, and a minimal reproduction. Do not open a public issue for an active vulnerability.

## Trust model

- The two-step Silo owner can replace or disable the funding adapter. The owner cannot change the auction terms or withdraw Silo tokens.
- The initial amount, positive floor, duration, resource token, recipient, app data, Settlement contract, and Vault Relayer are immutable.
- The Silo reads the Settlement fill record to determine whether to reset a sell token's clock. A commit without a full fill cannot restart the auction. A new full fill can raise the minimum above an earlier quote.
- Only the configured Settlement can call `Silo.commit(order)`. Use at most one active order per Silo and sell token in a batch.
- The Silo grants the Vault Relayer an unlimited allowance during `commit` if the allowance is too low for the order. A commit can succeed without a sale.
- CoW Protocol authorizes settlement solvers.
- Solver competition supplies price discovery. The Silo has no oracle.
- The Burner has no recovery function.

Before using a Silo, verify that the intended driver accepts its CoW order lifetime. The wire `validTo` includes the effective auction duration so the fill record cannot be cleared before the floor is reached. The Silo execution window is still at most five minutes.

CoW Protocol must also recognize the Silo as a surplus-capturing JIT owner for its surplus to count in solution scoring.
