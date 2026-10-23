# Operations

## Schedules

| Job | Schedule (UTC) | Script | Typical runtime |
|---|---|---|---|
| Daily baselines | `every day 01:30` | [010_daily_baselines.sql](../sql/bigquery/jobs/010_daily_baselines.sql) | Minutes |
| Z-score | `every 2 hours from 00:20 to 22:20` | [020_zscore_every_2h.sql](../sql/bigquery/jobs/020_zscore_every_2h.sql) | Under a few minutes |

Set the 20-minute offset to the load's normal finish time plus a margin. If loads routinely finish later, move the schedule, not the freshness threshold.

## Service levels (proposed)

| Measure | Target |
|---|---|
| Results available after the window closes | 30 minutes for 99% of windows |
| Feed response, cached | Under 300 ms at p95 |
| Feed or claim page, uncached | Under 4 s at p95 |
| Runs that succeed without manual action | 98% |

## Monitoring and alerts

| Signal | Source | Alert when |
|---|---|---|
| Z-score run failed or skipped | Scheduled query failure email, Pub/Sub notification state, `run_log.status` | Any failure. Page after 2 in a row. |
| Data is stale | `now − latest SUCCEEDED window_start` from `run_log`, exposed by the API as a metric | More than 4 hours 30 minutes |
| Baseline is stale | `MAX(built_at)` in `baseline_stats` | Older than 36 hours |
| Flag volume unusual | `run_log.flag_count` | More than 3× its 7-day median, which suggests a data problem rather than real anomalies |
| Notifier lag | Pub/Sub `oldest_unacked_message_age` on the subscription | More than 10 minutes |
| API errors and latency | Cloud Monitoring, Prometheus from `/actuator/prometheus` | p95 above targets, 5xx above 1% |
| BigQuery spend from the app | Billing export, filtered by job labels | Above budget |

## Runbook

**Run skipped as not loaded (`SKIPPED_NOT_LOADED`).** The load was late. Check the upstream load. When it lands, either wait, since the next run rescores the previous window, or run the script manually for that window.

**Run failed with an SQL error.** Check the transfer run log in BigQuery, under Scheduled queries and then the run. Common causes: a schema change in `edp.claims`, or a permission change. Fix, then rerun that run from the console.

**Too many flags at once.** Usually a data problem: duplicated load, missing columns, or a holiday. Check `run_log` counts against normal. If the data was bad, delete that window's rows from `anomalies` and `anomaly_transactions`, fix the data, and rerun. Add the date to `baseline_exclusions` if it should not shape future baselines.

**UI not refreshing.** Check the subscription backlog and the notifier pod. Browsers still poll every 5 minutes, so data arrives anyway, a little late.

**A client's results look wrong.** Look at `baseline_stats` for that client and slot. Check `n` and the stddev floor. Adjust `client_thresholds` for that client if needed.

## Backfill and manual runs

The z-score script reads `@run_time`. To score a specific window by hand, open the script, replace `@run_time` with a literal 20 minutes after the window's end, and run it in the console as `sa-zscore-job`:

```sql
DECLARE v_now TIMESTAMP DEFAULT TIMESTAMP '2026-10-20 12:20:00+00';  -- scores 10:00-12:00 and 08:00-10:00
```

Or use the scheduled query's "Schedule backfill" with a date range. Each run is delete-then-insert per window, so backfills can overlap safely. After a large backfill, rebuild baselines.

## Cost (order of magnitude)

Assumptions, to replace with real numbers: 10M claims a day, on-demand pricing at about $6.25 per TiB scanned. Check current pricing for your region and contract.

| Job | Approximate bytes scanned |
|---|---|
| Z-score, 12 runs a day, few columns, one day partition | A few GB a day |
| Flagged transactions insert, more columns | Low tens of GB a day |
| Daily baselines, 8 weeks of a few columns | Tens of GB a day |
| UI queries, 10 MB minimum each | Under 10 GB a day at 1,000 queries |

That totals well under 100 GB a day, a few TB a month, which is tens of dollars a month on demand. Storage for `anomaly_transactions` at 500k rows a day for 180 days is about 90M rows, a few tens of GB.

To reduce scans in the 2-hour job, cluster `edp.claims` by `client_id, received_ts`. The partition filter alone limits reads to the day, not the window.
