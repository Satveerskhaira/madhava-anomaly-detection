# Beyond the z-score

The z-score is phase 1. This page records the options discussed for later phases, so the design can grow without rework. The interactive comparison is in [diagrams/claims-anomaly-platform.html](diagrams/claims-anomaly-platform.html).

## Phase 2: client-specific rules and suppressions

| Kind | Effect | Stored | Applied |
|---|---|---|---|
| Threshold override | Per client and metric z threshold and minimum volume | `client_thresholds`, already in phase 1 | Each run |
| Custom rule | A client-specific condition, for example "days supply over 30 on opioid agonists, 5 or more claims in a window" | Cloud SQL as the source of truth, published to `edp_rules.client_rules` | Each run, by one fixed query that evaluates all rules |
| Suppression | Records a hit but doesn't alert, with a required reason and end date | Cloud SQL, published to `edp_rules.suppressions` | Each run |
| View filter | Narrows the feed for a user or team | `saved_view` in Cloud SQL | When the API reads |

Principles: users never write SQL, since rules are rows evaluated by fixed SQL with allow-listed fields and operators. Rules go through maker-checker approval and backtesting, are versioned, and take effect at the next run.

A rule publisher job in VPC 2 copies approved rules to BigQuery through PSC. It needs write access to `edp_rules` only.

## Phase 3: models trained on history

How it works: train on months of history to learn what normal looks like, then score each new window and claim against it, using the same feature code for training and scoring.

| Option | Training | Scoring | Custom library | Claims leave EDP |
|---|---|---|---|---|
| A. BigQuery ML | `CREATE MODEL` (ARIMA_PLUS, AUTOENCODER) | `ML.DETECT_ANOMALIES` in the run | Not used | No |
| B. Library scored in BigQuery | Vertex AI custom training | Export to ONNX, import to BigQuery ML, `ML.PREDICT` | Yes, if it exports to ONNX | No |
| C. Library on Vertex AI | Vertex AI custom training | Vertex batch prediction reading and writing BigQuery | Yes, any language | No |
| D. Library on app GKE, features only | GKE job | Scorer service reads feature views through PSC, writes scores back | Yes, as is | No, features cross |
| E. Library on app GKE, raw claims | GKE job | Scorer pulls 830k claims a run | Yes | Yes (avoid) |

**Recommended:** pluggable detectors in EDP. A `detectors` registry table lists each detector's engine (BigQuery ML, ONNX in BigQuery, Vertex), model version, scope and mode (live, shadow, off). Every engine writes one shared `model_scores` table, and a combine step merges model scores, z-scores and client rules into one severity. The app reads the same tables, so the UI doesn't change.

Contract a custom library implements:

```
fit(features_table, train_window, config) -> model_version, thresholds, feature_list
score(features_table, model_version)      -> rows in model_scores
explain(features_table, model_version)    -> top reasons per flagged row
export_onnx(model_version)                -> gs://.../model.onnx   (optional, enables option B)
```

Later, analysts' confirmed and false-positive labels from `flag_review` and `claim_review` can train a supervised model that re-ranks alerts.
