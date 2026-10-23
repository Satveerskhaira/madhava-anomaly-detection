# Serving and the web UI

## Reading BigQuery over JDBC

- **Driver.** Google's BigQuery JDBC driver, configured in [config/application.yml](../config/application.yml). Check the class name and property names against the driver version you install.
- **No live connection.** A JDBC connection to BigQuery is a client object. Each `SELECT` runs as a BigQuery job over HTTPS, typically 1 to 3 seconds. Keep the pool small.
- **Route.** The driver calls `bigquery.googleapis.com`, and with the high-throughput setting also `bigquerystorage.googleapis.com`. The private DNS zone resolves both to the PSC endpoint.
- **Billing.** `ProjectId` in the URL is where jobs run and bill: the app project. SQL uses fully qualified names such as `` `edp-project.edp_anomaly.anomalies` ``.
- **Credentials.** `OAuthType=3` uses Application Default Credentials, which GKE Workload Identity supplies for `sa-anomaly-api`. No key files.
- **Read-only.** The API only runs `SELECT`. All queries are in [sql/bigquery/queries/ui_queries.sql](../sql/bigquery/queries/ui_queries.sql) and always filter on the partition column.
- **Two datasources.** Spring Boot auto-configures only one. Bind `app.datasource.bigquery` and `app.datasource.reviews` with `@ConfigurationProperties`, create two `HikariDataSource` beans, and mark the Postgres one `@Primary` so Flyway and transactions use it.

```java
@Configuration
class DataSources {
  @Bean @Primary @ConfigurationProperties("app.datasource.reviews")
  HikariDataSource reviewsDataSource() { return new HikariDataSource(); }

  @Bean @ConfigurationProperties("app.datasource.bigquery")
  HikariDataSource bigQueryDataSource() { return new HikariDataSource(); }

  @Bean JdbcTemplate bigQueryJdbc(@Qualifier("bigQueryDataSource") DataSource ds) {
    JdbcTemplate t = new JdbcTemplate(ds);
    t.setQueryTimeout(60);
    return t;
  }
}
```

## Caching

| Key | Value | Expires |
|---|---|---|
| `latest_run` | Latest successful `run_log` row | Replaced on each run-complete event, 60 s TTL as a backstop |
| `feed:{run_id}:{hash of filter and client list}` | Feed response | 3 hours |
| `flag:{flag_id}:{run_id}:page:{n}` | Claim page | 3 hours |

Keys include the run id, so a new run never serves stale results and nothing needs to be deleted. A rescored previous window gets a new run id too.

## Merging review state

BigQuery returns anomaly rows, and Cloud SQL holds their review status. The API reads a page from BigQuery, then fetches status for those `flag_id` or `claim_id` values from Cloud SQL in one query, and merges them. For "unreviewed only", it fetches reviewed claim ids for the flag from Cloud SQL first, at most a few thousand, then excludes them in the BigQuery query or in memory.

## UI refresh

1. The z-score scheduled query finishes. Its Pub/Sub notification reports `SUCCEEDED` or `FAILED` with the run time.
2. The **refresh notifier**, a single consumer, pulls the message through PSC. On success it reads the latest `run_log` row, sets `latest_run` in Redis, and publishes `run-complete` on a Redis channel. On failure it publishes `run-failed`.
3. Every API replica subscribes to that Redis channel and pushes a server-sent event to the browsers connected to it.
4. Browsers show "New results, data as of 10:00" and reload the feed. On `run-failed` they show a banner that data may be late.
5. Browsers also poll `GET /api/runs/latest` every 5 minutes, in case an SSE connection dropped.

Why a single notifier with Redis fan-out: a Pub/Sub subscription delivers each message to only one subscriber client. With several API replicas, only one would hear about the run.

**Load balancer settings for SSE.** Raise the backend timeout, for example to 3600 seconds in the `BackendConfig` in [k8s/anomaly-api.yaml](../k8s/anomaly-api.yaml), and send a heartbeat comment every 25 seconds. At the default 30-second timeout, streams drop.

## UI screens

| Screen | Data | Actions |
|---|---|---|
| Feed | Flags for a time range, severity, client, review status, data as of | Filter, save view, open flag |
| Flag detail | Each metric: observed, expected, z, threshold; trend for the slot over 8 weeks | Set status, assign, note |
| Claims | `anomaly_transactions` for the flag, sorted by `claim_z`, 100 a page | Mark claims reviewed, confirmed or false positive. Export the visible page. |
| Run status | Recent `run_log` rows | None. Read-only for support. |

The 8-week trend can be read from `baseline_stats` plus recent `anomalies`. A dedicated `client_window_metrics` table written by the job would give a full history chart. See [open-questions.md](open-questions.md).

## JDBC to BigQuery, or a copy in Postgres

Start with JDBC plus the Redis cache. Add a Postgres copy if reviewers find it slow or usage grows. The API contract doesn't change. See [ADR 0003](decisions/0003-serve-ui-via-jdbc-with-cache.md).

| | JDBC to BigQuery (start here) | Copy each run into Cloud SQL |
|---|---|---|
| UI speed | 1 to 3 s uncached, sub-second with BI Engine | Milliseconds |
| Claim data in VPC 2 | Only what's on screen | The review working set |
| Review status filters | API merges two sources | One SQL query |
| Extra moving parts | Redis cache | Loader, retention, reconciliation |
| Cost per click | A BigQuery query of a few MB | None |

If you add the copy, the loader runs in VPC 2. On each run-complete event it reads that run's rows with the BigQuery Storage Read API through PSC, `COPY`s them into a staging table, upserts on `(run_date, flag_id, claim_id)`, checks counts against `run_log`, records `run_copy_log`, and only then fans out the refresh event. VPC 1 cannot push, because it has no network path to Cloud SQL's private IP.
