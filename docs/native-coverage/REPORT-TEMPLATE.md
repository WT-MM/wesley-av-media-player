# Native coverage report — <date / scope>

- Source revision / tag: `<revision>`; working-tree patch: `<receipt>`.
- Shipped executable path: `<path>`.
- **Shipped executable SHA-256:** `<64 lowercase hex>`.
- Measured executable path: `<path>`.
- **Measured executable SHA-256:** `<64 lowercase hex>`.
- Identity relationship: `<identical bytes / different candidate; no release proof claimed>`.
- Host / OS / codec services: `<details>`.

Every app receipt must retain its launch PID, argv, scratch HOME, all four
benchmark identity variables, asset SHA-256, executable SHA-256, exit status,
diagnostics and metrics. Verify the executable hash before and after the run.
A rebuild, signing or packaging step changes the measured identity; rerun the
relevant proofs against the shipped bytes before claiming release verification.
Historical receipts remain bound to their original hashes.

| Claim | Reproduction / reference | Observed result | Receipt | Limits |
| --- | --- | --- | --- | --- |
| <claim> | <asset hash, command, independent reference> | <measurement> | <link> | <scope> |

Decoded-audio receipts additionally identify the source/converter probe hash,
frame and channel counts, exact sample comparison, maximum error and lag.

Build: `<command / status>`. Ctest: `<passed / total / log>`.
Temporary reverts: `<mutated failures / byte-identical restores / log>`.
Final quiet six-second corpus: `<native / total; baseline; regressions / log>`.
Frozen-file hashes: `<before/after receipt>`. Deferrals: `<unproven claims>`.
