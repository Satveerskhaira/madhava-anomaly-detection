-- BigQuery DDL for the anomaly dataset in the EDP project (VPC 1).
--
-- Replace `edp-project` with the real project id before running.
-- Claim column types are assumptions; align them with edp.claims.
-- Run once. Every statement is idempotent (IF NOT EXISTS).

CREATE SCHEMA IF NOT EXISTS `edp-project.edp_anomaly`
OPTIONS (
  location = 'US',
  description = 'Z-score anomaly detection: baselines, results and flagged transactions'
);

-- Per-client overrides. Missing rows fall back to the defaults in the job script.
CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.client_thresholds` (
  client_id    STRING NOT NULL,
  metric       STRING NOT NULL,      -- claim_count | paid_amount | reject_rate
  z_threshold  FLOAT64,              -- default 3.0
  min_volume   INT64,                -- minimum expected claims in the slot to score; default 50
  enabled      BOOL,                 -- default TRUE
  reason       STRING,
  updated_by   STRING,
  updated_at   TIMESTAMP
)
OPTIONS (description = 'Per-client z-score thresholds. Maintained by the data team or the rule publisher.');

-- Days to leave out of baselines (outages, known incidents). client_id NULL = all clients.
CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.baseline_exclusions` (
  client_id    STRING,
  excluded_on  DATE NOT NULL,
  reason       STRING NOT NULL,
  added_by     STRING,
  added_at     TIMESTAMP
);

-- Rebuilt daily by jobs/010_daily_baselines.sql. Created here so readers never see a missing table.
CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.baseline_stats` (
  client_id  STRING NOT NULL,
  dow        INT64  NOT NULL,        -- 1 = Sunday ... 7 = Saturday (BigQuery DAYOFWEEK)
  slot       INT64  NOT NULL,        -- 0..11, 2-hour slot of the day in UTC
  metric     STRING NOT NULL,
  mean       FLOAT64,
  stddev     FLOAT64,
  n          INT64,                  -- number of past windows behind the mean
  built_at   TIMESTAMP
)
CLUSTER BY client_id;

CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.ndc_baseline` (
  drug_ndc    STRING NOT NULL,
  mean_ppu    FLOAT64,               -- paid amount per unit
  stddev_ppu  FLOAT64,
  n           INT64,
  built_at    TIMESTAMP
);

-- One row per client, window and metric that crossed its threshold.
CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.anomalies` (
  anomaly_id    STRING NOT NULL,     -- md5(client|window|metric), stable across reruns
  flag_id       STRING NOT NULL,     -- md5(client|window), groups the metrics of one client window
  run_id        STRING NOT NULL,
  client_id     STRING NOT NULL,
  window_start  TIMESTAMP NOT NULL,
  metric        STRING NOT NULL,
  observed      FLOAT64,
  mean          FLOAT64,
  stddev        FLOAT64,
  z             FLOAT64,
  z_threshold   FLOAT64,
  severity      STRING,              -- MEDIUM | HIGH
  created_at    TIMESTAMP
)
PARTITION BY DATE(window_start)
CLUSTER BY client_id, flag_id
OPTIONS (
  partition_expiration_days = 400,
  require_partition_filter = TRUE
);

-- Every claim behind a flagged client window. This is a governed copy for review,
-- inside EDP. Apply policy tags to member_id and prescriber_id (see docs/security-and-compliance.md).
CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.anomaly_transactions` (
  run_date       DATE NOT NULL,      -- DATE(window_start)
  run_id         STRING NOT NULL,
  flag_id        STRING NOT NULL,
  client_id      STRING NOT NULL,
  window_start   TIMESTAMP NOT NULL,
  metrics        ARRAY<STRING>,      -- metrics that flagged this window
  max_z          FLOAT64,
  claim_id       STRING NOT NULL,
  received_ts    TIMESTAMP,
  pharmacy_id    STRING,
  prescriber_id  STRING,
  member_id      STRING,
  drug_ndc       STRING,
  quantity       NUMERIC,
  days_supply    INT64,
  paid_amount    NUMERIC,
  claim_status   STRING,
  claim_z        FLOAT64,            -- paid per unit against the drug's 8-week norm
  created_at     TIMESTAMP
)
PARTITION BY run_date
CLUSTER BY client_id, flag_id
OPTIONS (
  partition_expiration_days = 180,
  require_partition_filter = TRUE
);

CREATE TABLE IF NOT EXISTS `edp-project.edp_anomaly.run_log` (
  run_id             STRING NOT NULL,
  window_start       TIMESTAMP NOT NULL,
  status             STRING NOT NULL, -- SUCCEEDED | SKIPPED_NOT_LOADED | FAILED
  claims_in_window   INT64,
  expected_claims    FLOAT64,
  anomaly_count      INT64,
  flag_count         INT64,
  flagged_txn_count  INT64,
  started_at         TIMESTAMP,
  finished_at        TIMESTAMP,
  message            STRING
)
PARTITION BY DATE(window_start)
OPTIONS (partition_expiration_days = 400);
