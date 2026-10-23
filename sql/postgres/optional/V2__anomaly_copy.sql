-- OPTIONAL. Only if you adopt the Postgres copy (docs/decisions/0003-serve-ui-via-jdbc-with-cache.md).
-- The loader in VPC 2 pulls each run's rows from BigQuery and upserts them here.
-- Partitioned by run_date so old data is dropped by detaching partitions, not by DELETE.

CREATE TABLE IF NOT EXISTS anomaly_copy (
    anomaly_id    text        PRIMARY KEY,
    flag_id       text        NOT NULL,
    run_id        text        NOT NULL,
    client_id     text        NOT NULL,
    window_start  timestamptz NOT NULL,
    metric        text        NOT NULL,
    observed      double precision,
    mean          double precision,
    stddev        double precision,
    z             double precision,
    severity      text
);
CREATE INDEX IF NOT EXISTS anomaly_copy_flag   ON anomaly_copy (flag_id);
CREATE INDEX IF NOT EXISTS anomaly_copy_window ON anomaly_copy (window_start DESC, client_id);

CREATE TABLE IF NOT EXISTS anomaly_transaction_copy (
    run_date      date        NOT NULL,
    flag_id       text        NOT NULL,
    claim_id      text        NOT NULL,
    client_id     text        NOT NULL,
    window_start  timestamptz NOT NULL,
    received_ts   timestamptz,
    pharmacy_id   text,
    drug_ndc      text,
    quantity      numeric,
    days_supply   integer,
    paid_amount   numeric,
    claim_status  text,
    claim_z       double precision,
    -- member_id / prescriber_id: copy only if policy allows them in VPC 2, preferably tokenized
    PRIMARY KEY (run_date, flag_id, claim_id)
) PARTITION BY RANGE (run_date);

CREATE INDEX IF NOT EXISTS atc_flag_z ON anomaly_transaction_copy (flag_id, claim_z DESC);

-- Example monthly partition; create ahead with pg_partman or a scheduled job.
CREATE TABLE IF NOT EXISTS anomaly_transaction_copy_2026_11
    PARTITION OF anomaly_transaction_copy
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

-- Which runs have been fully copied. The UI shows only runs listed here.
CREATE TABLE IF NOT EXISTS run_copy_log (
    run_id         text        PRIMARY KEY,
    window_start   timestamptz NOT NULL,
    anomaly_rows   integer     NOT NULL,
    txn_rows       integer     NOT NULL,
    copied_at      timestamptz NOT NULL DEFAULT now()
);
