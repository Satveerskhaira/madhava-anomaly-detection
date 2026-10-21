# Security and compliance

`anomaly_transactions` holds claim-level data, including member and prescriber identifiers, so treat it like `edp.claims`.

## Where PHI lives

| Location | PHI | Notes |
|---|---|---|
| `edp.claims` (VPC 1) | Yes | Source of truth |
| `edp_anomaly.anomaly_transactions` (VPC 1) | Yes, a subset | Governed copy inside EDP for review. 180-day partition expiry. |
| `edp_anomaly.anomalies` | No | Client-level totals only |
| Pub/Sub run notification | No | Run time and status only |
| Redis cache (VPC 2) | Masked claim pages, short-lived | Encrypt in transit. Keys expire after 3 hours. Restrict to the API's network. |
| Cloud SQL (VPC 2) | Claim ids and reviewer notes | Tell reviewers not to paste member details into notes |
| Optional Postgres copy (VPC 2) | Yes, if adopted | Needs its own compliance review. Copy tokenized ids where possible. |
| Browser | What's on screen | No local storage of claim data |

## Masking

- Put Dataplex policy tags on `member_id` and `prescriber_id` in `anomaly_transactions`.
- Add a masking rule, such as SHA-256 or last four characters, for the default reader. Grant clear values only to roles that need them.
- `sa-anomaly-api` gets the masked reader role by default. If some reviewers must see clear values, decide between two approaches:
  - a second service account with fine-grained reader, used only for those users' requests;
  - per-user credentials, end-user OAuth to BigQuery.

  This is recorded in [open-questions.md](open-questions.md).

## Identity and access

| Service account | Project | Permissions |
|---|---|---|
| `sa-zscore-job` | EDP | Data Viewer on `edp` (claims), Data Editor on `edp_anomaly`, Job User in EDP |
| BigQuery Data Transfer service agent | EDP | Token Creator on `sa-zscore-job`, Pub/Sub Publisher on the topic |
| `sa-anomaly-api` | App | Data Viewer on `edp_anomaly` only, Job User and Read Session User in app, Cloud SQL Client and Instance User |
| `sa-anomaly-notifier` | App | Pub/Sub Subscriber on `anomaly-run-complete-app` |

- No account in VPC 2 can read `edp.claims`, or write to any EDP table.
- Reviewers sign in through IAP with the corporate IdP. The API maps their groups to the clients they may see and filters every query by those clients.
- Label each BigQuery job with a hashed reviewer id, so data access audit logs trace reads to a person.

## VPC Service Controls

If the EDP project is inside a perimeter:

- Use the `vpc-sc` bundle on the PSC endpoint, as the Terraform default does.
- Add an ingress rule allowing `sa-anomaly-api` and `sa-anomaly-notifier`, from the VPC 2 network or the app project, to `bigquery.googleapis.com`, `bigquerystorage.googleapis.com` and `pubsub.googleapis.com`.
- Query jobs run in the app project and read EDP data. The ingress rule must allow that cross-project read. Test with a dry run before go-live.

## Network

- No public IPs. The internal load balancer only, reached over the corporate network or VPN.
- Cloud Armor policy on the backend. IAP required on every path.
- Cloud SQL and Redis on private services access only. TLS on Redis. IAM database authentication on Cloud SQL.

## Audit and retention

| Record | Where | Keep |
|---|---|---|
| Who read which claims | BigQuery data access audit logs | Per org policy |
| Who changed review state | `review_audit` in Cloud SQL | Per org policy, at least as long as the anomaly |
| What the job flagged and why | `anomalies` with mean, stddev, z and threshold | 400 days |
| Flagged claims | `anomaly_transactions` | 180 days, set to the review period |
