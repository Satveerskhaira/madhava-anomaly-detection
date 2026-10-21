# 0002 · Schedule the job with BigQuery scheduled queries

**Status:** Accepted

## Context

The detection is plain SQL. Something has to run it every 2 hours after the load, and run the baselines daily. We want nothing extra to deploy or operate in VPC 1.

## Decision

Use two BigQuery scheduled queries, created by Terraform from the scripts in `sql/bigquery/jobs`:

- `every day 01:30` for baselines
- `every 2 hours from 00:20 to 22:20` for the z-score

They run as `sa-zscore-job`. The z-score schedule publishes run notifications to the `anomaly-run-complete` Pub/Sub topic. The script checks the window is loaded and fails cleanly if not. Each run rescores the previous window for late claims. Every window is delete-then-insert, so reruns are safe.

## Alternatives

| Option | Choose it when |
|---|---|
| Cloud Workflows with an Eventarc trigger on load completion | Runs must start exactly when the load finishes, or retries must be automatic |
| Dataform | The SQL grows into many dependent steps that need assertions and Git-based releases |
| Spring Batch CronJob in VPC 2 | The app team must own scheduling and can't deploy into EDP. Needs write access to EDP from VPC 2. |

The SQL is identical in all of them, so switching later is cheap.

## Consequences

- Time-based, not event-based. A late load means a failed run and a later rescore.
- Retries are manual or come from the next run.
- Scheduled query text lives in Git and is deployed by Terraform, so changes go through review.
