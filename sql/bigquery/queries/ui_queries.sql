-- Read-only queries the Anomaly API runs over JDBC (VPC 2 -> PSC -> BigQuery).
-- Positional ? parameters, in order, as used with Spring JdbcTemplate.
-- Every query filters on the partition column so it reads a few MB.

-- Q1. Latest successful run (cached; drives "data as of" and refresh checks)
SELECT run_id, window_start, finished_at, anomaly_count, flag_count, flagged_txn_count
FROM `edp-project.edp_anomaly.run_log`
WHERE DATE(window_start) >= DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 2 DAY)
  AND status = 'SUCCEEDED'
ORDER BY window_start DESC
LIMIT 1;

-- Q2. Anomaly feed for a window range, one row per flag (client window)
-- params: from_date (DATE), to_date (DATE), from_ts (TIMESTAMP), to_ts (TIMESTAMP), client_id (STRING or NULL)
SELECT
  flag_id,
  client_id,
  window_start,
  ARRAY_AGG(STRUCT(metric, observed, mean, z, severity) ORDER BY ABS(z) DESC) AS metrics,
  MAX(ABS(z))                                                              AS max_z,
  IF(LOGICAL_OR(severity = 'HIGH'), 'HIGH', 'MEDIUM')                      AS severity
FROM `edp-project.edp_anomaly.anomalies`
WHERE DATE(window_start) BETWEEN ? AND ?
  AND window_start >= ? AND window_start < ?
  AND (? IS NULL OR client_id = ?)          -- bind client_id twice
GROUP BY flag_id, client_id, window_start
ORDER BY window_start DESC, max_z DESC
LIMIT 500;

-- Q3. One flag's metrics (detail header)
-- params: run_date (DATE), flag_id (STRING)
SELECT metric, observed, mean, stddev, z, z_threshold, severity
FROM `edp-project.edp_anomaly.anomalies`
WHERE DATE(window_start) = ?
  AND flag_id = ?
ORDER BY ABS(z) DESC;

-- Q4. Flagged transactions for one flag, most unusual first, 100 per page
-- params: run_date (DATE), flag_id (STRING), offset (INT64)
SELECT claim_id, received_ts, pharmacy_id, prescriber_id, member_id, drug_ndc,
       quantity, days_supply, paid_amount, claim_status, claim_z
FROM `edp-project.edp_anomaly.anomaly_transactions`
WHERE run_date = ?
  AND flag_id = ?
ORDER BY claim_z DESC NULLS LAST, claim_id
LIMIT 100 OFFSET ?;

-- Q5. Count for paging
-- params: run_date (DATE), flag_id (STRING)
SELECT COUNT(*) AS total
FROM `edp-project.edp_anomaly.anomaly_transactions`
WHERE run_date = ?
  AND flag_id = ?;

-- Q6. "Unreviewed only": exclude claim ids already reviewed (ids come from Cloud SQL)
-- params: run_date (DATE), flag_id (STRING), reviewed_ids (ARRAY<STRING>)
-- Array parameters need the BigQuery client library or driver support for arrays;
-- otherwise filter in the API after Q4.
SELECT claim_id, received_ts, pharmacy_id, drug_ndc, quantity, days_supply,
       paid_amount, claim_status, claim_z
FROM `edp-project.edp_anomaly.anomaly_transactions`
WHERE run_date = ?
  AND flag_id = ?
  AND claim_id NOT IN UNNEST(?)
ORDER BY claim_z DESC NULLS LAST, claim_id
LIMIT 100;
