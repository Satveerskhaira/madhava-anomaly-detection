-- Daily baseline refresh. Runs as a BigQuery scheduled query once a day, for example 01:30 UTC.
--
-- Builds:
--   baseline_stats : mean and stddev per client, metric, weekday and 2-hour slot over the last 8 weeks
--   ndc_baseline   : paid amount per unit per drug over the same period, for the claim-level z-score
--
-- Windows with no claims count as zero (from the client's first day onward), so a quiet
-- slot keeps a true baseline and a client that goes silent can be detected.
-- Days listed in baseline_exclusions are left out.

DECLARE v_end   DATE DEFAULT DATE_SUB(CURRENT_DATE('UTC'), INTERVAL 1 DAY);
DECLARE v_start DATE DEFAULT DATE_SUB(v_end, INTERVAL 55 DAY);   -- 56 days = 8 weeks

CREATE OR REPLACE TABLE `edp-project.edp_anomaly.baseline_stats`
CLUSTER BY client_id
AS
WITH agg AS (
  SELECT
    client_id,
    received_date                               AS d,
    DIV(EXTRACT(HOUR FROM received_ts), 2)      AS slot,
    CAST(COUNT(*) AS FLOAT64)                   AS claim_count,
    CAST(SUM(paid_amount) AS FLOAT64)           AS paid_amount,
    SAFE_DIVIDE(COUNTIF(claim_status = 'REJECTED'), COUNT(*)) AS reject_rate
  FROM `edp-project.edp.claims`
  WHERE received_date BETWEEN v_start AND v_end
  GROUP BY client_id, d, slot
),
clients AS (
  SELECT client_id, MIN(d) AS first_day FROM agg GROUP BY client_id
),
grid AS (
  SELECT c.client_id, d, slot
  FROM clients c,
       UNNEST(GENERATE_DATE_ARRAY(v_start, v_end)) AS d,
       UNNEST(GENERATE_ARRAY(0, 11)) AS slot
  WHERE d >= c.first_day
),
filled AS (
  SELECT
    g.client_id,
    EXTRACT(DAYOFWEEK FROM g.d)      AS dow,
    g.slot,
    IFNULL(a.claim_count, 0)         AS claim_count,
    IFNULL(a.paid_amount, 0)         AS paid_amount,
    a.reject_rate                    AS reject_rate   -- stays NULL when there were no claims
  FROM grid g
  LEFT JOIN agg a USING (client_id, d, slot)
  WHERE NOT EXISTS (
    SELECT 1 FROM `edp-project.edp_anomaly.baseline_exclusions` x
    WHERE x.excluded_on = g.d AND (x.client_id IS NULL OR x.client_id = g.client_id)
  )
)
SELECT
  client_id, dow, slot, metric,
  AVG(value)          AS mean,
  STDDEV_SAMP(value)  AS stddev,
  COUNT(value)        AS n,
  CURRENT_TIMESTAMP() AS built_at
FROM filled
UNPIVOT (value FOR metric IN (claim_count, paid_amount, reject_rate))   -- NULLs are excluded
GROUP BY client_id, dow, slot, metric;

CREATE OR REPLACE TABLE `edp-project.edp_anomaly.ndc_baseline`
AS
SELECT
  drug_ndc,
  AVG(ppu)            AS mean_ppu,
  STDDEV_SAMP(ppu)    AS stddev_ppu,
  COUNT(*)            AS n,
  CURRENT_TIMESTAMP() AS built_at
FROM (
  SELECT drug_ndc, SAFE_DIVIDE(paid_amount, quantity) AS ppu
  FROM `edp-project.edp.claims`
  WHERE received_date BETWEEN v_start AND v_end
    AND claim_status = 'PAID'
    AND quantity > 0
)
WHERE ppu IS NOT NULL
GROUP BY drug_ndc
HAVING COUNT(*) >= 30;
