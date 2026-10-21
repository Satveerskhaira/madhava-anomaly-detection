# Detection logic

## The calculation

```
z = (observed − mean) ÷ max(stddev, 5% of mean)
flag when |z| ≥ threshold      (default 3, per client in client_thresholds)
severity HIGH when |z| ≥ threshold + 2, otherwise MEDIUM
```

- **Observed:** one client's total in one 2-hour window, for each metric.
- **Mean and stddev:** the same client, metric, weekday and 2-hour slot over the last 8 weeks. Monday 08:00–10:00 is compared only with past Mondays 08:00–10:00, so normal daily and weekly shape doesn't flag.

## Metrics

| Metric | Observed value | Catches |
|---|---|---|
| `claim_count` | Claims received in the window | Spikes, and drops to zero, such as a client feed outage |
| `paid_amount` | Sum of paid amount | Cost spikes from high-cost drugs or pricing errors |
| `reject_rate` | Rejected ÷ all claims | Plan setup or eligibility problems |

Adding a metric means adding it to `cur` and the `CASE` in the job, and to the `UNPIVOT` list in the baseline job. Average days supply and average quantity are common next candidates.

## Windows and time zone

- Windows are fixed 2-hour slots starting on even hours **UTC**: 00:00, 02:00 … 22:00. Slot = `DIV(hour, 2)`, 0–11.
- The job runs at hh:20 after each even hour and scores the window that just closed.
- Baselines use the same UTC slots. If the business wants local-time slots, change both jobs to `EXTRACT(HOUR FROM received_ts AT TIME ZONE 'America/Chicago')` together. Daylight saving then moves one slot twice a year.
- Assumption: `received_date = DATE(received_ts)` in UTC. If the claims partition column is in local time, adjust the partition filters.

## Guards against false alarms

| Guard | Default | Why |
|---|---|---|
| Minimum history | 4 past weeks for that weekday and slot (`n >= 4`) | No baseline, no score. New clients are skipped until they have history. |
| Minimum volume | Expected claims in the slot ≥ 50 | Tiny clients swing wildly in percentage terms |
| Stddev floor | 5% of the mean | A very flat history would make a small change look huge |
| Zero-filled baseline | Empty slots count as 0 from the client's first day | Keeps quiet overnight slots honest, and lets a silent client score |
| Exclusions | `baseline_exclusions` | Outage days and known incidents don't distort the baseline |
| Freshness check | Claims ≥ 50% of expected volume | A late load fails the run instead of producing false "drop" alerts |

## Which transactions are loaded for review

For each flagged client window (`flag_id`), the job inserts that client's claims in the window into `anomaly_transactions`:

| Flag on | Claims loaded |
|---|---|
| `claim_count` or `paid_amount` spike | All claims in the window |
| `reject_rate` only | Rejected claims only |
| A drop | Whatever claims exist. A full drop has none, and the flag alone is the signal. |

Each claim gets `claim_z`: its paid amount per unit compared with the drug's 8-week mean and stddev (`ndc_baseline`). The UI sorts by it, so the claims most likely to explain the spike come first. It is a ranking aid, not a second detector.

Rough volume: if 20 client windows flag in a run with about 2,000 claims each, that is 40,000 rows a run, about 500,000 a day.

## Late-arriving claims and reruns

- Each run rescores the **previous** window as well as the current one. Each window is delete-then-insert, so late claims are picked up and rows are never duplicated.
- `anomaly_id` and `flag_id` are hashes of client, window and metric, so they are stable across reruns. Review state in Cloud SQL stays attached.
- Claims arriving more than 4 hours late are not rescored automatically. Use a backfill (see [operations.md](operations.md)).

## Worked example

Client C-4411, Monday 10:00–12:00 UTC, metric `claim_count`. The figures are illustrative.

| | Value |
|---|---|
| Past 8 Mondays, same slot | 1,020 · 980 · 1,110 · 1,050 · 990 · 1,070 · 1,000 · 1,040 |
| Mean | 1,032.5 |
| Stddev | 44.0 |
| Floor (5% of mean) | 51.6, so the floor is used |
| Observed today | 1,310 |
| z | (1,310 − 1,032.5) ÷ 51.6 = 5.38 |
| Result | Flagged, HIGH (≥ 3 + 2) |

The 1,310 claims go to `anomaly_transactions`. The reviewer sees them sorted by `claim_z`, and the top rows show 140 claims for one high-cost NDC at one pharmacy.

## Limits of a z-score

- It looks at one metric at a time. Changes in mix, such as normal volume but a shift to one drug at a new pharmacy, need a multivariate model. See [model-roadmap.md](model-roadmap.md).
- Holidays and month-start refill surges aren't in a weekday baseline. Add them to `baseline_exclusions` or raise thresholds on those days.
- Distributions of paid amount are skewed. If false positives are high, try median and MAD (`z = 0.6745 × (x − median) ÷ MAD`) or log-transformed amounts. Both are small changes to the two jobs.
