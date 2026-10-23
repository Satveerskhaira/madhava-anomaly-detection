# Claim surveillance: reject anomalies

Design notes for a surveillance page where account managers watch their clients' pharmacy claim reject rates. They can compare each client with its own history, its line of business and the whole book of business, and drill down to the claims behind a flag. Claims are in MongoDB today.

This complements the BigQuery z-score pipeline in the rest of this repo. The detection idea is the same. This page covers the MongoDB version, reject-rate scoring, and the UI.

## Data

One document per claim transaction:

| Field | Example | Notes |
|---|---|---|
| `claim_number` | `262964100587` | |
| `claim_seq` | `001` | Resubmissions and reversals get later sequences |
| `pharmacy` | NCPDP id and name | |
| `drug` | NDC and name | |
| `claim_ts` | `2026-10-23T14:02:11Z` | Store in UTC |
| `reject_code` | `75` | Empty or null when paid |
| `client_id` | `C10421` | |
| `carrier` | `LKMD01` | |
| `lob` | `Med D` or `Non-Med D` | Carrier line of business |

Both paid and rejected transactions are present, so every rate has a true denominator.

## Metrics

| Metric | Definition | Use |
|---|---|---|
| Reject % (client) | client rejects ÷ client claims in the window | What is scored |
| Reject % by carrier | Same, per carrier of the client | Shows whether one carrier explains a spike |
| Reject % by LOB | All clients' rejects ÷ all clients' claims in the same LOB and window | Peer context |
| Reject % for the book of business | All rejects ÷ all claims in the window | Overall context |
| Reject code share | Rejects with a code ÷ all rejects | Explains why a client flagged |

Decide whether the rate is per transaction (each submission, including resubmissions) or per final claim outcome. Per transaction is the usual reject-rate measure and is what this design assumes. Exclude reversals from both numerator and denominator.

## Anomaly method

### Score each client against its own history

Reject % is a proportion, so use a z-score for a rate:

```
p   = rejects / claims                         current window
p0  = rejects / claims                         same weekday and same clock times, prior 8 weeks, pooled
se  = sqrt(p0 × (1 − p0) / claims)
z   = (p − p0) / se
```

- Volume is built in. A client with 20 claims needs a much bigger jump to reach the same z than a client with 5,000.
- Line of business and book of business are context, not the baseline. Clients differ in drug mix and plan design, so a client that always runs 4 points above the book is not news. A change from its own history is. Show peer gaps beside the flag rather than flagging on them.

### Status rules

| Status | Rule | Meaning |
|---|---|---|
| Above normal | z ≥ 3 **and** p − p0 ≥ 2 percentage points | Raise to the account manager |
| Watch | z ≥ 2 **and** p − p0 ≥ 1 point | Worth a look |
| Below normal | z ≤ −3 **and** p − p0 ≤ −2 points | Informational. A sudden drop can follow a plan change. |
| Normal | Anything else | |
| No claims | No claims in the window | Not a reject anomaly. See volume below. |

The minimum point change matters for big clients. At 5,000 claims a window, a 0.5-point wobble already gives a large z.

**Over-dispersion.** If real week-to-week variation is wider than the binomial formula expects, the formula flags too often. Use `se = max(binomial se, standard deviation of the 8 weekly rates)` and tune by backtesting.

### Clients that don't always have claims

| Situation | Handling |
|---|---|
| Fewer than 30 claims in the 2-hour window | Widen that client's window to 6 hours, then 24 hours, until it has 30 claims. Show "24h window, low volume". |
| Zero claims in the window | There is no rate to score. Show "No claims, usually about N". |
| Expected volume is meaningful and actual is zero | Separate volume check, not a reject check: with expected λ claims, P(0) = e^−λ. Flag a possible feed issue when that is under 1%. |
| Under about 4 weeks of history | Don't score yet. Optionally compare with the line of business as context only. |

### Windows

| | Choice | Why |
|---|---|---|
| Current window | Rolling 2 hours, recalculated every 15 minutes | Recent enough to act on. Long enough to have volume. |
| History | Same weekday, same clock times, prior 8 weeks | Reject patterns differ by time of day and weekday |
| Second view | Last 24 hours against the same weekday | Slower trends, and the fallback for small clients |
| Exclusions | Holidays and known incident days removed from history | They distort the usual rate |

Store timestamps in UTC and decide whether slots follow UTC or a business time zone. Use the same rule in both the rollup and the scoring.

## Live per transaction, or on a time window?

On a time window. A single claim has no reject rate, and recalculating on every claim gives jumpy numbers with no extra value. A rolling 2-hour window refreshed every 15 minutes is effectively real time for account managers.

If specific real-time rules are needed later, such as one pharmacy suddenly rejecting everything, add them as a separate stream rule. They don't replace the windowed score.

## Batch or on request?

Both, split by cost.

**Batch, every 15 minutes:**

1. **Roll up** claims into 15-minute buckets per client, carrier and line of business, with counts per reject code.
2. **Score** every client from the rollups and write one score document per client and window.

**On request from the UI:**

- Overview and client pages read the precomputed scores, plus small rollup queries for trends and custom ranges.
- The claims drill-down is the only raw-claims query. It is indexed, limited to one client and one window, and paged.

**Why not compute on request from raw claims?** At about 10 million claims a day, each page load would scan millions of documents and compete with claim processing. Two account managers looking a second apart could also see different numbers. Precomputed scores make every user see the same numbers and load in milliseconds.

## MongoDB design

### Collections

| Collection | One document per | Written by | Read by |
|---|---|---|---|
| `claims` (existing) | Claim transaction | Claim processing | Drill-down only |
| `claim_stats_15m` | Client × carrier × LOB × 15-minute bucket | Rollup job, every 15 min | Scoring job, trends, custom ranges |
| `client_reject_scores` | Client × window (2h, 24h) × scoring time | Scoring job, every 15 min | Overview and client pages |
| `score_runs` | Job run | Both jobs | "Data as of", monitoring |

Rollup document:

```json
{
  "client_id": "C10421", "carrier": "LKMD01", "lob": "Med D",
  "bucket": { "$date": "2026-10-23T14:00:00Z" },
  "claims": 412, "rejects": 97,
  "by_code": { "75": 51, "79": 18, "70": 12, "MR": 9, "76": 7 },
  "updated_at": { "$date": "2026-10-23T14:17:03Z" }
}
```

Score document:

```json
{
  "client_id": "C10421", "lob": "Med D", "window": "2h",
  "window_start": { "$date": "2026-10-23T12:15:00Z" }, "window_end": { "$date": "2026-10-23T14:15:00Z" },
  "window_used": "2h",
  "claims": 4820, "rejects": 1210, "rate": 0.251,
  "usual_rate": 0.142, "se": 0.0050, "z": 21.7,
  "status": "ABOVE_NORMAL",
  "lob_rate": 0.146, "bob_rate": 0.135,
  "top_codes": [{ "code": "75", "share": 0.53, "usual_share": 0.28 }],
  "carriers": [{ "carrier": "LKMD01", "claims": 3120, "rate": 0.326, "usual_rate": 0.146, "z": 28.9 }],
  "scored_at": { "$date": "2026-10-23T14:17:40Z" }
}
```

### Rollup job (every 15 minutes)

Recompute the last 3 hours and replace those buckets. Late claims are then counted and nothing is double counted. Requires MongoDB 5.0 or later for `$dateTrunc`.

```js
const now = new Date();
const from = new Date(Math.floor((now.getTime() - 3 * 3600e3) / 900e3) * 900e3); // 15-min aligned

db.claims.aggregate([
  { $match: { claim_ts: { $gte: from, $lt: now } } },
  { $group: {
      _id: {
        client_id: "$client_id", carrier: "$carrier", lob: "$lob",
        bucket: { $dateTrunc: { date: "$claim_ts", unit: "minute", binSize: 15 } },
        code: { $ifNull: ["$reject_code", "PAID"] }
      },
      n: { $sum: 1 } } },
  { $group: {
      _id: { client_id: "$_id.client_id", carrier: "$_id.carrier", lob: "$_id.lob", bucket: "$_id.bucket" },
      claims:  { $sum: "$n" },
      rejects: { $sum: { $cond: [{ $eq: ["$_id.code", "PAID"] }, 0, "$n"] } },
      codes:   { $push: { k: "$_id.code", v: "$n" } } } },
  { $project: {
      _id: 0,
      client_id: "$_id.client_id", carrier: "$_id.carrier", lob: "$_id.lob", bucket: "$_id.bucket",
      claims: 1, rejects: 1,
      by_code: { $arrayToObject: { $filter: { input: "$codes", cond: { $ne: ["$$this.k", "PAID"] } } } },
      updated_at: "$$NOW" } },
  { $merge: { into: "claim_stats_15m", on: ["client_id", "carrier", "lob", "bucket"],
              whenMatched: "replace", whenNotMatched: "insert" } }
], { allowDiskUse: true });
```

The last bucket is partial, which is expected. The next run replaces it.

### Scoring job (every 15 minutes, after the rollup)

1. **Current window.** The 8 buckets ending at the latest complete 15 minutes. Sum claims, rejects and codes per client, per carrier, per LOB and overall.
2. **History.** The same 8 bucket times on each of the prior 8 same weekdays, which is 64 bucket timestamps. Sum per client and per carrier:

   ```js
   const windowBuckets = [...]; // 8 Date objects for the current window
   const histBuckets = [];
   for (let w = 1; w <= 8; w++)
     for (const b of windowBuckets) histBuckets.push(new Date(b.getTime() - w * 7 * 86400e3));

   db.claim_stats_15m.aggregate([
     { $match: { bucket: { $in: histBuckets } } },
     { $group: { _id: "$client_id", claims: { $sum: "$claims" }, rejects: { $sum: "$rejects" } } }
   ]);
   ```

3. For clients under 30 claims, repeat with a 24-hour window.
4. Compute rate, usual rate, se, z, status, LOB and book rates, top codes and carrier rows, then upsert into `client_reject_scores`.
5. Write a `score_runs` document. The UI reads its time for "data as of".

The scoring is a few thousand documents of arithmetic. It can live in a small Spring Boot job, scheduled with ShedLock or as a Kubernetes CronJob, or in an Atlas scheduled trigger if you're on Atlas.

### Indexes

```js
db.claims.createIndex({ client_id: 1, claim_ts: -1 });
db.claims.createIndex({ client_id: 1, reject_code: 1, claim_ts: -1 });
db.claims.createIndex({ claim_ts: 1 });          // rollup range scan; skip if an equivalent exists

db.claim_stats_15m.createIndex({ client_id: 1, carrier: 1, lob: 1, bucket: 1 }, { unique: true }); // required by $merge
db.claim_stats_15m.createIndex({ bucket: 1 });
db.claim_stats_15m.createIndex({ lob: 1, bucket: 1 });

db.client_reject_scores.createIndex({ window: 1, scored_at: -1, status: 1 });
db.client_reject_scores.createIndex({ client_id: 1, window: 1, scored_at: -1 });
```

Keep rollups for about 13 months, so 8 weeks of history plus year-over-year comparisons. Keep scores for 90 days, with a TTL index on `scored_at`.

### Protecting the claims system

- Run the rollup aggregation against an analytics node or a secondary (`readPreference: secondaryPreferred`), so claim processing isn't slowed.
- Only the drill-down reads raw claims from the UI. It is always limited to one client, one window and 50 rows a page, using the indexes above.
- If MongoDB load becomes a concern at this volume, stream claims to BigQuery and use the pipeline in this repo's [sql/bigquery](../sql/bigquery). The UI and API contract don't change.

## UI

A clickable prototype was built on a Claude design canvas, private to the owner: <https://claude.ai/artifact/HW9STTgmvgW5pERBBt481Z>

| Screen | Shows | Actions |
|---|---|---|
| Overview | Book-of-business, Med D and Non-Med D reject % against usual. Clients flagged. Client table: claims, rejects, reject %, usual (own history) ± range, deviation, gap to LOB, gap to book, status. | Switch between "My clients" and "All clients". Pick clients to focus on. Switch between a rolling 2-hour and a 24-hour window. Sort by deviation, reject % or volume. |
| Client | Claims, reject %, gap to LOB and book. A plain-language "why" line. A comparison chart of client, usual band, LOB and book. A 24-hour trend against the usual range. Carrier table. Reject codes now against usual share. | Open claims for all rejects or one reject code |
| Claims | Claim number, sequence, time, pharmacy and NCPDP, drug, carrier, LOB, result and reject code | Filter by reject code. Include paid claims. Page 50 at a time. |

Every screen shows "data as of" from the last scoring run. Account managers see only their clients unless their role allows the book of business.

## API sketch

| Endpoint | Reads |
|---|---|
| `GET /api/scores?window=2h&scope=mine&clients=C1,C2` | Latest `client_reject_scores` for the scope, plus LOB and book totals |
| `GET /api/clients/{id}?window=2h` | Latest score document for the client |
| `GET /api/clients/{id}/trend?hours=24` | `claim_stats_15m` buckets for the client, plus usual rate per slot |
| `GET /api/clients/{id}/claims?from&to&code&includePaid&page` | `claims`, indexed and paged |
| `GET /api/runs/latest` | `score_runs` |

## Enterprise checklist

- **Access.** Map account managers to their clients, enforce it in the API on every query, and audit claim-level reads.
- **Reliability.** Jobs are idempotent: they replace buckets and upsert scores. Alert when the last run is over 30 minutes old or a run fails.
- **Consistency.** The UI shows one scoring run at a time, so every user sees the same numbers.
- **Tuning.** Backtest the thresholds on 4 to 8 weeks of history before go-live. Target a flag volume the account managers can act on.
- **PHI.** The claim drill-down shows pharmacy, drug and codes. Add member fields only if a role needs them, masked by default.

## Open questions

1. Reject rate per transaction or per final claim outcome, and how to treat reversals.
2. Slots in UTC or Central time.
3. Default thresholds: z 3 and 2 points, or tuned per LOB.
4. Whether "Below normal" should notify or stay informational.
5. Whether volume drops, such as a client going silent, belong on this page or a separate feed-health page.
