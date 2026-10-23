# Testing and validation

## Before the first run

1. **Dry-run every script.** `bq query --use_legacy_sql=false --dry_run < sql/bigquery/jobs/020_zscore_every_2h.sql`, with `@run_time` replaced by a literal. Check bytes processed and that there are no errors.
2. **Check the column mapping.** Compare the columns in [data-model.md](data-model.md#mapping-to-edpclaims) with the real `edp.claims`, including the status values `PAID` and `REJECTED`.
3. **Build baselines once by hand** and sanity-check them: `n` close to 8 for active clients, no negative means, stddev present.

## Backtest on history

Before anyone receives alerts, replay the job over the last 4 to 8 weeks into a scratch dataset.

1. Copy the `edp_anomaly` DDL into `edp_anomaly_backtest`.
2. Rebuild the baseline as of each backtest day. Simplest: run the daily script with `CURRENT_DATE()` replaced by the backtest date, so a day never sees its own data.
3. Run the z-score script for every window in the period, by looping over `@run_time` values.
4. Measure:

| Measure | Query | Target to agree with reviewers |
|---|---|---|
| Flags per day | `COUNT(DISTINCT flag_id)` by day | Within team capacity, for example under 50 |
| Flags per client | Count by client | No client flagging most days |
| Known incidents caught | Join to a list of past confirmed incidents | All or nearly all |
| Claims to review per flag | Average `COUNT(*)` from `anomaly_transactions` | Manageable with sorting by `claim_z` |

5. Tune `client_thresholds`, the minimum volume and the stddev floor until the numbers agree. Record the chosen defaults in [ADR 0001](decisions/0001-zscore-in-bigquery-sql.md).

## Data checks in every run

The script already fails when the window is below 50% of the expected volume. Add these to the script, or as a follow-up scheduled query, when needed:

- No duplicate `claim_id` in `edp.claims` for the window. Duplicates inflate counts.
- `paid_amount` and `quantity` not null for paid claims.
- Count in `anomaly_transactions` equals the sum of claims in the flagged windows.

## Unit tests for the SQL

Make a small fixture dataset, `edp_test.claims`, with hand-built cases:

| Case | Expected |
|---|---|
| Client with normal volume | No flag |
| Client at 3× normal volume in one slot | `claim_count` flag, HIGH |
| Client with zero claims in a slot where it normally has 500 | `claim_count` flag (drop), no transactions |
| Reject rate from 2% to 20% | `reject_rate` flag, only rejected claims loaded |
| Client with 2 weeks of history | Not scored |
| Late claims for the previous window | Previous window rescored, no duplicate rows |
| Rerun of the same window | Identical results, same ids |

Run the scripts against the fixture with the project names swapped, and assert on the output tables. These can run in CI with a sandbox project.

## API and UI

- Contract tests against [api/openapi.yaml](../api/openapi.yaml).
- Integration test that a run notification on the subscription leads to an SSE event on every API replica.
- Load test at expected reviewer concurrency, measuring BigQuery job concurrency and latency on cache misses.
- Access test: a reviewer entitled to client A can't read client B through any endpoint.

## Acceptance

- Two weeks in shadow: the job runs and the UI is available to a pilot group, with no alerts sent.
- Reviewers mark every flag. Target a false-positive rate the team accepts, for example under 50% at launch. Tune and repeat.
