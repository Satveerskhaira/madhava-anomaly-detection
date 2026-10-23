# Open questions

*Before build* items change the SQL, the schema or the access model. Settle them first.

| # | Question | Why it matters | When | Default if not answered |
|---|---|---|---|---|
| 1 | What is a "client": plan sponsor, employer group, carrier? | It is the grain of every baseline and flag | Before build | Plan sponsor |
| 2 | Real column names and status values in `edp.claims`, and is `received_date` UTC? | The SQL assumes names and UTC | Before build | As in [data-model.md](data-model.md) |
| 3 | When does each 2-hour load usually finish, and how late can claims arrive? | Sets the schedule offset and the late-data rescore window | Before build | Done by hh:15, under 4 hours late |
| 4 | Windows in UTC or local time? | Changes the slot calculation in both jobs | Before build | UTC |
| 5 | Which metrics at launch? | Each adds flags to review | Before build | Claim count, paid amount, reject rate |
| 6 | Should reviewers ever see member or prescriber ids in clear? | Decides masking and whether a second service account or per-user credentials are needed | Before build | Masked for everyone |
| 7 | Is the EDP project inside a VPC Service Controls perimeter? | Ingress rules and the PSC bundle | Before build | Yes, `vpc-sc` bundle |
| 8 | Which project pays for UI queries? | Job User role and budget alerts | Before build | App project |
| 9 | Can the app team deploy scheduled queries into the EDP project, or does the data team own them? | Ownership of the jobs and Terraform | Before build | Data team applies the EDP Terraform |
| 10 | How long must flagged transactions be kept? | Partition expiry and storage | Before launch | 180 days |
| 11 | How many reviewers, and how many at once? | JDBC-only versus a Postgres copy, BI Engine | Before launch | Under 50 named, under 10 at once |
| 12 | Who edits client thresholds: data team in SQL, or the UI? | The UI path needs the rule publisher from phase 2 | Phase 2 | Data team |
| 13 | Is a full 8-week trend chart needed on flag detail? | Needs a `client_window_metrics` table written each run | Phase 2 | Show the baseline mean and band only |
| 14 | Should alerts go anywhere besides the UI (email, Teams, ServiceNow)? | Adds a notifier route | Phase 2 | UI only |
| 15 | Is there a custom anomaly library, and in what language? Can it export to ONNX? | Picks option B or C in [model-roadmap.md](model-roadmap.md) | Phase 3 | Not used |
