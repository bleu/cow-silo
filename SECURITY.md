# Security

CoW Silo is unaudited. Do not use this version with production funds.

Send a private report to `security@bleu.fi`. Include the affected commit, the impact, and a minimal reproduction. Do not open a public issue for an active vulnerability.

## Trust model

- A Silo has no administrator.
- The resource token, recipient, app data, Settlement contract, and Vault Relayer are immutable.
- Only the configured Settlement contract can create a transient order commitment.
- The Vault Relayer receives an unlimited token allowance after the first settlement for that token.
- CoW Protocol authorizes settlement solvers.
- Solver competition supplies price discovery. The Silo has no oracle.
- The Burner has no recovery function.

The design needs a correct CoW surplus-capturing JIT configuration. A deployment is not production-ready until CoW Protocol recognizes its Silo owners.
