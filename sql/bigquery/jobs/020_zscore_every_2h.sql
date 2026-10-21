-- Z-score detection. Runs as a BigQuery scheduled query every 2 hours,
-- 20 minutes after each even hour UTC ("every 2 hours from 00:20 to 22:20").
--
-- Each run:
--   1. Works out the 2-hour window that just closed.
--   2. Checks the window is loaded (claims >= 50% of the expected volume). If not, logs and fails.
--   3. Scores that window and rescores the window before it, to pick up late-arriving claims.
--      Each window is delete-then-insert, so reruns and backfills are safe.
--   4. Loads every claim behind each flagged client window into anomaly_transactions.
--   5. Writes run_log. The schedule's Pub/Sub notification tells VPC 2 the run finished.
--
-- @run_time is supplied by the scheduler. For a manual run or backfill, replace @run_time
-- with a literal such as TIMESTAMP '2026-10-20 10:20:00+00'.

DECLARE v_now         TIMESTAMP DEFAULT @run_time;
DECLARE v_current     TIMESTAMP;
DECLARE v_run_id      STRING;
DECLARE v_started     TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
DECLARE v_claims      INT64;
DECLARE v_expected    FLOAT64;

-- Defaults when a client has no row in client_thresholds.
DECLARE v_default_z   FLOAT64 DEFAULT 3.0;
DECLARE v_default_min INT64   DEFAULT 50;
DECLARE v_stddev_floor_pct FLOAT64 DEFAULT 0.05;   -- stddev is at least 5% of the mean

-- 1. The window that just closed. Windows start on even hours UTC.
SET v_current = TIMESTAMP_SUB(
  TIMESTAMP_TRUNC(v_now, HOUR),
  INTERVAL (2 + MOD(EXTRACT(HOUR FROM v_now), 2)) HOUR);
SET v_run_id = FORMAT_TIMESTAMP('%Y%m%dT%H%M%S', v_now);

-- 2. Is the window loaded?
SET v_claims = (
  SELECT COUNT(*)
  FROM `edp-project.edp.claims`
  WHERE received_date = DATE(v_current)
    AND received_ts >= v_current
    AND received_ts <  TIMESTAMP_ADD(v_current, INTERVAL 2 HOUR)
);

SET v_expected = (
  SELECT SUM(mean)
  FROM `edp-project.edp_anomaly.baseline_stats`
  WHERE metric = 'claim_count'
    AND dow  = EXTRACT(DAYOFWEEK FROM v_current)
    AND slot = DIV(EXTRACT(HOUR FROM v_current), 2)
);

IF v_claims < 0.5 * IFNULL(v_expected, 0) THEN
  INSERT INTO `edp-project.edp_anomaly.run_log`
    (run_id, window_start, status, claims_in_window, expected_claims, started_at, finished_at, message)
  VALUES
    (v_run_id, v_current, 'SKIPPED_NOT_LOADED', v_claims, v_expected, v_started, CURRENT_TIMESTAMP(),
     'Window below 50% of expected volume; load probably not finished');
  RAISE USING MESSAGE = FORMAT('Window %t has %d claims, expected about %.0f', v_current, v_claims, v_expected);
END IF;

-- 3-4. Score the previous window (late data) and the current window.
FOR w IN (
  SELECT ws
  FROM UNNEST([TIMESTAMP_SUB(v_current, INTERVAL 2 HOUR), v_current]) AS ws
)
DO
  DELETE FROM `edp-project.edp_anomaly.anomalies`
  WHERE DATE(window_start) = DATE(w.ws) AND window_start = w.ws;

  DELETE FROM `edp-project.edp_anomaly.anomaly_transactions`
  WHERE run_date = DATE(w.ws) AND window_start = w.ws;

  INSERT INTO `edp-project.edp_anomaly.anomalies`
    (anomaly_id, flag_id, run_id, client_id, window_start, metric,
     observed, mean, stddev, z, z_threshold, severity, created_at)
  WITH cur AS (
    SELECT
      client_id,
      CAST(COUNT(*) AS FLOAT64)          AS claim_count,
      CAST(SUM(paid_amount) AS FLOAT64)  AS paid_amount,
      SAFE_DIVIDE(COUNTIF(claim_status = 'REJECTED'), COUNT(*)) AS reject_rate
    FROM `edp-project.edp.claims`
    WHERE received_date = DATE(w.ws)
      AND received_ts >= w.ws
      AND received_ts <  TIMESTAMP_ADD(w.ws, INTERVAL 2 HOUR)
    GROUP BY client_id
  ),
  -- Drive from the baseline so a client that sends nothing still scores (a drop to zero).
  expected AS (
    SELECT *
    FROM `edp-project.edp_anomaly.baseline_stats`
    WHERE dow  = EXTRACT(DAYOFWEEK FROM w.ws)
      AND slot = DIV(EXTRACT(HOUR FROM w.ws), 2)
      AND n >= 4                         -- at least 4 past weeks for this weekday and slot
  ),
  volume AS (
    SELECT client_id, mean AS mean_claims FROM expected WHERE metric = 'claim_count'
  ),
  scored AS (
    SELECT
      e.client_id,
      e.metric,
      e.mean,
      e.stddev,
      CASE e.metric
        WHEN 'claim_count' THEN IFNULL(c.claim_count, 0)
        WHEN 'paid_amount' THEN IFNULL(c.paid_amount, 0)
        WHEN 'reject_rate' THEN c.reject_rate
      END                                         AS observed,
      COALESCE(t.z_threshold, v_default_z)        AS z_threshold
    FROM expected e
    JOIN volume v USING (client_id)
    LEFT JOIN cur c USING (client_id)
    LEFT JOIN `edp-project.edp_anomaly.client_thresholds` t
      ON t.client_id = e.client_id AND t.metric = e.metric
    WHERE v.mean_claims >= COALESCE(t.min_volume, v_default_min)
      AND COALESCE(t.enabled, TRUE)
  ),
  z AS (
    SELECT
      *,
      SAFE_DIVIDE(observed - mean,
                  GREATEST(IFNULL(stddev, 0), ABS(mean) * v_stddev_floor_pct)) AS z
    FROM scored
    WHERE observed IS NOT NULL
  )
  SELECT
    TO_HEX(MD5(CONCAT(client_id, '|', CAST(w.ws AS STRING), '|', metric))),
    TO_HEX(MD5(CONCAT(client_id, '|', CAST(w.ws AS STRING)))),
    v_run_id, client_id, w.ws, metric, observed, mean, stddev, z, z_threshold,
    IF(ABS(z) >= z_threshold + 2, 'HIGH', 'MEDIUM'),
    CURRENT_TIMESTAMP()
  FROM z
  WHERE ABS(z) >= z_threshold;

  INSERT INTO `edp-project.edp_anomaly.anomaly_transactions`
    (run_date, run_id, flag_id, client_id, window_start, metrics, max_z,
     claim_id, received_ts, pharmacy_id, prescriber_id, member_id, drug_ndc,
     quantity, days_supply, paid_amount, claim_status, claim_z, created_at)
  WITH flagged AS (
    SELECT
      flag_id, client_id, window_start,
      ARRAY_AGG(metric ORDER BY metric)   AS metrics,
      MAX(ABS(z))                         AS max_z,
      LOGICAL_AND(metric = 'reject_rate') AS rejects_only
    FROM `edp-project.edp_anomaly.anomalies`
    WHERE DATE(window_start) = DATE(w.ws) AND window_start = w.ws
    GROUP BY flag_id, client_id, window_start
  )
  SELECT
    DATE(w.ws), v_run_id, f.flag_id, f.client_id, f.window_start, f.metrics, f.max_z,
    c.claim_id, c.received_ts, c.pharmacy_id, c.prescriber_id, c.member_id, c.drug_ndc,
    c.quantity, c.days_supply, c.paid_amount, c.claim_status,
    SAFE_DIVIDE(SAFE_DIVIDE(c.paid_amount, c.quantity) - n.mean_ppu, n.stddev_ppu),
    CURRENT_TIMESTAMP()
  FROM flagged f
  JOIN `edp-project.edp.claims` c
    ON c.client_id = f.client_id
   AND c.received_date = DATE(w.ws)
   AND c.received_ts >= w.ws
   AND c.received_ts <  TIMESTAMP_ADD(w.ws, INTERVAL 2 HOUR)
  LEFT JOIN `edp-project.edp_anomaly.ndc_baseline` n
    ON n.drug_ndc = c.drug_ndc
  -- A drop in volume has no claims to show. A reject-rate spike shows only the rejects.
  WHERE NOT f.rejects_only OR c.claim_status = 'REJECTED';
END FOR;

-- 5. Record the run for the current window.
INSERT INTO `edp-project.edp_anomaly.run_log`
  (run_id, window_start, status, claims_in_window, expected_claims,
   anomaly_count, flag_count, flagged_txn_count, started_at, finished_at, message)
SELECT
  v_run_id, v_current, 'SUCCEEDED', v_claims, v_expected,
  (SELECT COUNT(*) FROM `edp-project.edp_anomaly.anomalies`
    WHERE DATE(window_start) = DATE(v_current) AND window_start = v_current),
  (SELECT COUNT(DISTINCT flag_id) FROM `edp-project.edp_anomaly.anomalies`
    WHERE DATE(window_start) = DATE(v_current) AND window_start = v_current),
  (SELECT COUNT(*) FROM `edp-project.edp_anomaly.anomaly_transactions`
    WHERE run_date = DATE(v_current) AND window_start = v_current),
  v_started, CURRENT_TIMESTAMP(), NULL;
