# Security

CoW Silo is unaudited. Do not use this version with production funds.

Send a private report to `security@bleu.fi`. Include the affected commit, the impact, and a minimal reproduction. Do not open a public issue for an active vulnerability.

## Trust model

These rules describe the current JIT proof of concept.

- The two-step Silo owner can change the minimum buy amount and hook gas limit, and replace or disable the funding adapter. The owner cannot withdraw Silo tokens.
- The resource token, recipient, appData JSON shape, Settlement contract, and Vault Relayer are immutable. The document must encode the current owner-set hook gas limit.
- Any account can prepare a token and trigger optional funding into the fixed Silo without a later trade. Source approvals must permit this early transfer.
- Preparation records a token balance for the current transaction, not one order hash. Any order for that token must meet all order rules and match both the recorded balance and the current full balance.
- The complete appData hash must match the canonical JSON document for this Silo, sell token, and current hook gas limit. Publishing that document and executing its hook remain solver integration requirements.
- The Vault Relayer receives an unlimited token allowance after the first successful preparation for that token.
- CoW Protocol authorizes settlement solvers.
- Solver competition supplies price discovery. The Silo has no oracle.
- The Burner has no recovery function.

For the JIT proof of concept, CoW Protocol must recognize Silo owners before their JIT surplus counts in scoring. The planned production path uses regular Order Book orders. That path needs an independent review of the contract changes and their interaction with order validation and settlement.
