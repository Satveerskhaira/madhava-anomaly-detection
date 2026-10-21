# 0003 · Serve the UI over JDBC to BigQuery with a Redis cache

**Status:** Accepted, revisit at launch

## Context

The web app in VPC 2 needs the anomaly feed and the flagged claims. Results change only every 2 hours. Claim data is PHI.

## Decision

The Spring Boot API reads `anomalies` and `anomaly_transactions` with Google's BigQuery JDBC driver through the PSC endpoint, using parameterized, partition-filtered queries. Results are cached in Redis by run id. Review state is merged in from Cloud SQL.

## Alternatives

**Copy each run into Cloud SQL Postgres.** A loader in VPC 2 would pull each run through PSC on run-complete, and the UI would read Postgres in milliseconds. Not chosen at launch because it puts claim-level PHI in VPC 2 and adds a loader, retention and reconciliation. The schema is ready in `sql/postgres/optional`.

## Revisit when

- Uncached p95 is above 4 seconds and reviewers complain.
- Concurrent reviewers push against BigQuery concurrency limits or budget.
- Most screens need filters that mix review status with claim fields.

## Consequences

- 1 to 3 seconds on cache misses. BI Engine can bring that down.
- Every UI query costs a small BigQuery charge, at least 10 MB per table read.
- The API merges results from two databases for review-status filters.
