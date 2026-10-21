# 0007 · Refresh the UI with Pub/Sub, Redis fan-out and server-sent events

**Status:** Accepted

## Context

Results change every 2 hours. Open browsers should update without reviewers reloading, and without the app holding a live connection to BigQuery.

## Decision

1. The z-score scheduled query's run notification goes to Pub/Sub.
2. A single refresh notifier in VPC 2 pulls it through PSC, updates `latest_run` in Redis, and publishes on a Redis channel.
3. Every API replica relays the event to its browsers as server-sent events.
4. Browsers also poll `/api/runs/latest` every 5 minutes.

## Alternatives

- **Polling only.** Simple, but updates arrive up to 5 minutes late and every browser polls.
- **WebSockets.** Two-way, which isn't needed here. SSE is plain HTTP and passes through the load balancer and IAP more easily.
- **A subscription per API replica.** Works, but subscriptions must be created and cleaned up as pods scale.

## Consequences

- The load balancer backend timeout must be long, for example 3600 seconds, with a 25-second heartbeat.
- If the notifier is down, browsers still update within 5 minutes through polling.
