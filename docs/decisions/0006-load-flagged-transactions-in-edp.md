# 0006 · Copy flagged claims into `anomaly_transactions` inside EDP

**Status:** Accepted

## Context

Reviewers need every claim behind a flagged client window. Querying `edp.claims` for each drill-down would give the app read access to all claims.

## Decision

The 2-hour job inserts the claims behind each flag into `edp_anomaly.anomaly_transactions`, in the same project and governance boundary as the claims, with a per-claim `claim_z` for ranking. The table is partitioned by `run_date`, expires after 180 days, and has policy tags on identifiers. The app can read this table but not `edp.claims`.

## Alternatives

- **Re-query `edp.claims` on drill-down.** No copy, but it gives the app's service account access to all claims, and each query reads the full day partition.
- **Store claim ids only.** Smaller, but the drill-down still needs claims access.

## Consequences

- A governed subset copy of PHI, about 500k rows a day, inside EDP.
- Rescoring a window replaces its transactions. Ids stay stable.
