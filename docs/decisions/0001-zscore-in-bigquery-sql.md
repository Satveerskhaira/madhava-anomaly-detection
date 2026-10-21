# 0001 · Detect anomalies with a z-score in BigQuery SQL

**Status:** Accepted

## Context

About 10M claims a day arrive in BigQuery in 2-hour loads. We need client-level anomaly detection that is explainable to reviewers, cheap to run, and keeps claim data inside the EDP project.

## Decision

Compute a z-score per client, metric and 2-hour window in BigQuery SQL. Compare it with the same weekday and slot over the last 8 weeks, and flag at |z| ≥ 3 by default, with per-client overrides. Guards: at least 4 weeks of history, a minimum expected volume, a stddev floor of 5% of the mean, zero-filled baselines, and exclusion days.

## Alternatives

- **Dataproc or Spark.** Can compute the same thing, but adds a cluster or job runtime for something plain SQL does where the data already is.
- **Pulling data to the app cluster and scoring in Java.** Moves claims and PHI into VPC 2 every run, with no benefit for a z-score.
- **ML models now.** Kept for phase 3 ([model-roadmap.md](../model-roadmap.md)). A z-score gives a baseline to measure models against, and labels to train them.

## Consequences

- One metric at a time. Mix changes need a model later.
- Holidays and month-start surges need exclusions or threshold tuning.
- Thresholds and guards must be tuned by backtest before alerts go live ([testing-and-validation.md](../testing-and-validation.md)).
