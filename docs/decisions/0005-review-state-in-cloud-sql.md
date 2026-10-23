# 0005 · Keep review state in Cloud SQL, not BigQuery

**Status:** Accepted

## Context

Reviewers change status and add notes on flags and individual claims, often one row at a time.

## Decision

Store review state (`flag_review`, `claim_review`, `review_audit`, `saved_view`) in Cloud SQL for PostgreSQL in VPC 2, keyed by `flag_id` and `claim_id`. These ids are stable across reruns because they are hashes of client, window and metric.

## Alternatives

- **BigQuery DML.** Single-row updates are slow, quota-limited and costly, and the app would need write access to EDP.

## Consequences

- The API merges BigQuery rows with Cloud SQL status.
- Review state stays with the app team, and labels are available for later supervised models.
- To analyse review outcomes in BigQuery, export or federate `flag_review` and `claim_review` later.
