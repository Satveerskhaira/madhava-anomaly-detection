# Architecture decision records

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-zscore-in-bigquery-sql.md) | Detect anomalies with a z-score in BigQuery SQL | Accepted |
| [0002](0002-schedule-with-bigquery-scheduled-query.md) | Schedule the job with BigQuery scheduled queries | Accepted |
| [0003](0003-serve-ui-via-jdbc-with-cache.md) | Serve the UI over JDBC to BigQuery with a Redis cache | Accepted, revisit at launch |
| [0004](0004-private-service-connect-no-peering.md) | Reach Google APIs through Private Service Connect, no VPC peering | Accepted |
| [0005](0005-review-state-in-cloud-sql.md) | Keep review state in Cloud SQL, not BigQuery | Accepted |
| [0006](0006-load-flagged-transactions-in-edp.md) | Copy flagged claims into `anomaly_transactions` inside EDP | Accepted |
| [0007](0007-ui-refresh-via-pubsub-and-sse.md) | Refresh the UI with Pub/Sub, Redis fan-out and server-sent events | Accepted |

Format: context, decision, alternatives, consequences. Add a new ADR rather than editing an accepted one; mark the old one superseded.
