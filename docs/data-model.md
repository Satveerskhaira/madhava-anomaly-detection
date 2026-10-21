# Data model

DDL: [sql/bigquery/ddl/001_edp_anomaly_tables.sql](../sql/bigquery/ddl/001_edp_anomaly_tables.sql) and [sql/postgres/V1__review_schema.sql](../sql/postgres/V1__review_schema.sql).

## Identifiers

| Id | Built from | Stable across reruns | Used for |
|---|---|---|---|
| `run_id` | Scheduled run time, `YYYYMMDDTHHMMSS` | No, each run gets its own | Tracing which run wrote a row |
| `flag_id` | `md5(client_id \| window_start)` | Yes | One client window. Links anomalies, transactions and review state. |
| `anomaly_id` | `md5(client_id \| window_start \| metric)` | Yes | One metric's result |
| `claim_id` | From `edp.claims` | Yes | One claim |

## BigQuery · `edp_anomaly` (VPC 1)

| Table | Grain | Written by | Partition / cluster | Retention |
|---|---|---|---|---|
| `client_thresholds` | Client × metric | Data team, or a future rule publisher | None | Permanent |
| `baseline_exclusions` | Date (× client) | Data team | None | Permanent |
| `baseline_stats` | Client × weekday × slot × metric | Daily job, full rewrite | Cluster `client_id` | Rewritten daily |
| `ndc_baseline` | Drug NDC | Daily job, full rewrite | None | Rewritten daily |
| `anomalies` | Client × window × metric that flagged | 2-hour job | `DATE(window_start)` / `client_id, flag_id` | 400 days |
| `anomaly_transactions` | Flag × claim | 2-hour job | `run_date` / `client_id, flag_id` | 180 days, or the review period |
| `run_log` | Run | 2-hour job | `DATE(window_start)` | 400 days |

`anomalies` and `anomaly_transactions` require a partition filter, so an unfiltered query fails instead of scanning everything.

### `anomaly_transactions` columns

Only the columns a reviewer needs are copied from `edp.claims`: claim id, received time, pharmacy, prescriber, member, NDC, quantity, days supply, paid amount, status. Add others deliberately, and tag any new identifier column with a policy tag.

## Cloud SQL · `anomaly_review` (VPC 2)

| Table | Grain | Purpose |
|---|---|---|
| `flag_review` | Flag | Status (NEW, IN_REVIEW, CONFIRMED, FALSE_POSITIVE, NO_ACTION), assignee, note |
| `claim_review` | Flag × claim | Claim-level status and note |
| `review_audit` | Change | Append-only history of who changed what and when |
| `saved_view` | User or team filter | Feed filters. They never change detection. |

Review state is kept out of BigQuery on purpose. Single-row updates are slow and quota-limited there, and review state belongs to the app.

## Optional: Postgres copy

If reviewers need millisecond filtering, [sql/postgres/optional/V2__anomaly_copy.sql](../sql/postgres/optional/V2__anomaly_copy.sql) defines copies of `anomalies` and `anomaly_transactions` partitioned by `run_date`, plus `run_copy_log`. See [ADR 0003](decisions/0003-serve-ui-via-jdbc-with-cache.md) for when to adopt it.

## Mapping to `edp.claims`

The SQL assumes these columns. Rename to match the real table.

| Assumed column | Meaning |
|---|---|
| `client_id` | Plan sponsor or client the claim belongs to |
| `received_date` | Partition column, `DATE(received_ts)` in UTC |
| `received_ts` | When the claim arrived in the load |
| `claim_id`, `pharmacy_id`, `prescriber_id`, `member_id`, `drug_ndc` | Identifiers |
| `quantity`, `days_supply`, `paid_amount` | Amounts |
| `claim_status` | Values `PAID`, `REJECTED`, `REVERSED` |
