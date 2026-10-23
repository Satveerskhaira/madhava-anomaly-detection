# 0004 · Reach Google APIs through Private Service Connect, no VPC peering

**Status:** Accepted

## Context

BigQuery and Pub/Sub sit with the EDP project, and the app runs in a separate VPC. Traffic must stay private.

## Decision

Create a PSC endpoint for Google APIs in VPC 2, using the `vpc-sc` bundle when EDP is in a perimeter, plus a private Cloud DNS zone that resolves `googleapis.com` and `*.googleapis.com` to the endpoint IP. The BigQuery JDBC driver, the Storage Read API and Pub/Sub clients use their normal hostnames.

## Alternatives

- **VPC peering between VPC 1 and VPC 2.** Not needed: BigQuery and Pub/Sub are Google APIs, not hosts inside VPC 1.
- **Private Google Access only.** Works, but PSC gives a fixed internal IP and fits VPC Service Controls more cleanly.

## Consequences

- The private zone overrides all `googleapis.com` names for VPC 2. Every Google API call from VPC 2 goes through the endpoint, which is intended.
- VPC Service Controls ingress rules are needed for the VPC 2 service accounts.
