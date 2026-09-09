---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-09-09
---

# SPIKE: Remote Applier Connectivity and Partition-Scoped Access to Postgres

**Jira**: [HYPERFLEET-1519](https://redhat.atlassian.net/browse/HYPERFLEET-1519)

**Parent epic**: [HYPERFLEET-1518](https://redhat.atlassian.net/browse/HYPERFLEET-1518) (Desire Store on Postgres)

**Prior art**:

- [Desire store on API Postgres spike (HYPERFLEET-1432)](desire-store-api-postgres-spike.md)
- [Desire identity and ownership spike (HYPERFLEET-1421)](spike-desire-identity-ownership.md)

## Table of Contents

- [Overview](#overview)
- [API-mediated vs. direct DB access](#api-mediated-vs-direct-db-access)
- [Recommended: API-mediated access](#recommended-api-mediated-access)
- [Alternative considered: Direct DB access](#alternative-considered-direct-db-access)
  - [Network exposure](#network-exposure)
  - [Authentication](#authentication)
  - [Partition scoping](#partition-scoping)
- [Latency considerations](#latency-considerations)
- [Decision](#decision)
- [Trade-offs](#trade-offs)
- [Open questions](#open-questions)

---

## Overview

The Postgres desire store spike ([HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432)) validated Postgres as the desire store backend. The desire identity spike ([HYPERFLEET-1421](https://redhat.atlassian.net/browse/HYPERFLEET-1421)) deferred cryptographic enforcement to production backends. This spike resolves two remaining questions:

- **Connectivity**: how do the adapter and applier, running on separate OCI clusters, connect to the desire store?
- **Partition isolation**: how do we ensure applier-A can only access cluster-A's rows?

Deployment is OCI-only. The hub (API, Postgres, Sentinel, Broker) and management clusters (HyperShift, Applier) both run on OCI, on separate clusters; on-prem/multi-cloud portability is a future scenario (ADR-0019), not a requirement here.

---

## API-mediated vs. direct DB access

The central question: should clients connect to the desire store through an API layer, or directly to Postgres?

| Dimension | API-mediated access | Direct DB access |
|-----------|---------------------|-------------------|
| Postgres exposure | Never exposed | Exposed via network path (internal or external, depending on mechanism) |
| Partition isolation | Application-level, in the API layer | Requires RLS, per-cluster credentials, or app-level enforcement at the client |
| Credential lifecycle | None; JWT via K8s TokenRequest API, auto-rotated | Requires dedicated design; complexity depends on mechanism chosen |
| New components to build | New endpoints (existing API or separate service) | None, if using existing cloud/proxy infra; a service, if credential-brokering is added |
| Single point of failure | Yes, if endpoints are added to the existing API | No new single point, beyond Postgres itself |

---

## Recommended: API-mediated access

Don't expose Postgres directly. Put a gRPC/REST service on the hub in front of the desire store. Both the adapter and applier talk to the service, not to the DB.

- Pros:
  - Postgres is never exposed
  - Access control enforced in application code
  - Single endpoint to secure
  - Partition isolation becomes an application-level problem, simpler to reason about and test
  - Decouples adapter and applier from DB backend; could swap Postgres for another store without changing clients
  - May be able to reuse existing Envoy + Authorino auth infrastructure
- Cons:
  - New endpoints to build (on existing API or as a separate service)
  - Adds a network hop and serialization overhead
  - Desire store interface must be reimplemented as REST/gRPC endpoints
  - API becomes a single point of failure for both resource CRUD and desire delivery (if endpoints are added to existing API)

**Partition isolation**: enforced in the API layer. Envoy strips caller-supplied identity/tenant headers; Authorino validates the JWT and injects trusted identity headers. The API derives partition scope only from those injected headers (not from JWT claims or any client-supplied partition parameter). Mismatched or override attempts are rejected. No RLS, per-cluster DB credentials, or credential-brokering service needed on the DB side.

**Client authentication** (adapter/applier → API): JWT through Envoy + Authorino (same as Sentinel today).

**Client credential lifecycle**: handled by existing infrastructure. Tokens are short-lived and auto-rotated via the K8s TokenRequest API. No manual provisioning or rotation workflow needed. Decommissioning a management cluster means deleting its service account; bound tokens then fail TokenReview after a short invalidation window (Kubernetes typically allows up to ~60s after `metadata.deletionTimestamp`), and any remaining lifetime ends at token expiry.

---

## Alternative considered: Direct DB access

Clients connect to Postgres directly without an API layer. This requires three additional decisions, each with operational overhead that API-mediated access avoids, since Postgres is never exposed to the adapter or applier.

### Network exposure

How a client reaches Postgres from a different cluster.

- **VPN / tunnel**: works everywhere, Postgres stays internal; but requires VPN infrastructure HyperFleet doesn't have, plus operational overhead (key management, monitoring, failover)
- **External endpoint with mTLS**: simple topology, no VPN infra; but exposes Postgres publicly (even if mTLS-gated), larger attack surface, certificate distribution and rotation needed
- **Proxy sidecar** (e.g. PgBouncer): client code is unaware of connectivity details, good for connection pooling at scale; but still needs an underlying tunnel or endpoint, extra process to deploy per client
- **Cloud-native private link** (OCI Service Gateway): low latency, cloud-managed, no public IP; but cloud-specific setup, doesn't cover on-prem or air-gapped, requires a cloud-managed DB service

### Authentication

How a client proves its identity to Postgres.

- **Username/password over TLS**: works everywhere, simple to implement; but credentials are static secrets that must be distributed and rotated
- **mTLS client certificates**: no shared secret to leak, identity is cryptographic; but certificate provisioning and rotation needed per client, not all cloud-managed Postgres services support it
- **Cloud IAM auth** (e.g. OCI instance principal): no static credentials, short-lived tokens auto-rotated; but cloud-specific, doesn't work on-prem or cross-cloud, requires a cloud-managed DB service

### Partition scoping

How a client is restricted to its own management cluster's rows.

- **Application-level enforcement**: simple to implement, easy to test; but a bug in the store library could leak rows across partitions, no defense-in-depth
- **RLS with shared credentials**: DB enforces isolation, even a buggy client can't read another partition's rows; but client must set session variable correctly, harder to debug (silent empty results if wrong)
- **Per-cluster DB credentials**: strongest isolation (credential = identity = partition scope); but credential provisioning scales linearly with clusters, rotation and revocation complexity increases per cluster
- **Credential-brokering service**: short-lived credentials reduce blast radius; but new service to build and operate, becomes a single point of failure, still needs RLS or per-cluster credentials at the DB layer

---

## Latency considerations

The poll interval is 5s (assumed from [HYPERFLEET-1432](https://redhat.atlassian.net/browse/HYPERFLEET-1432) load modeling, configurable). Each poll does a partition read and status writes. This applies regardless of which path (API-mediated or direct DB) is chosen.

Clients connect from separate OCI clusters. Same-cloud, same-region round-trip latency is expected to be low. Against a 5s poll interval, the extra network hop from API-mediated access is expected to fit the budget; this should be confirmed with load testing during implementation if production concurrency is a concern.

---

## Decision

**API-mediated access**, for the reasons above: it reuses existing auth infrastructure, avoids three additional decision dimensions that direct DB access requires (network exposure, authentication, partition scoping), and the 5s poll interval is expected to leave headroom for the extra network hop. See [Trade-offs](#trade-offs) below for what this costs.

---

## Trade-offs

### What We Gain

- Postgres is never exposed outside the hub cluster; no DB-level network exposure, authentication, or partition-scoping decisions to make
- Partition isolation is application code, testable with unit tests, no RLS or per-cluster DB credentials
- Client credential lifecycle is already solved: JWT via K8s TokenRequest API, auto-rotated, revocable by deleting a service account (short invalidation window, then token expiry)
- Reuses Envoy + Authorino auth infrastructure already planned for the hub
- Adapter and applier use the same auth path as Sentinel, reducing the number of auth mechanisms in the system

### What We Lose / What Gets Harder

- New endpoints must be built for the desire store interface (partition read, status write, desire write)
- The API becomes a single point of failure for both resource CRUD and desire delivery (if endpoints are added to the existing API); separating into a dedicated service avoids this but adds deployment complexity
- Adds a network hop and serialization overhead between client and store
- Tighter coupling between client release cadence and API release cadence (clients depend on API contract stability)

### Acceptable Because

- The desire store interface is small and well-defined (partition read, status write, desire write); the endpoint surface area is bounded
- The 5s poll interval is expected to leave headroom for the extra network hop
- API-mediated access eliminates three entire categories of decisions (network exposure, authentication, partition scoping) and their associated operational overhead
- Remote appliers gain an API dependency for partition reads and status writes (unlike direct DB access, which would depend on Postgres availability instead). That still lands on the same hub failure domain Sentinel already relies on for cluster/nodepool state; client timeout/retry/degraded behavior is left to implementation

---

## Open questions

- **OCI security constraints**: Ask the Oracle team about OCI-specific security requirements or restrictions (e.g. network policies, required auth mechanisms, managed DB limitations). With API-mediated access, this is no longer blocking the path decision, but may still be relevant for the hub cluster's internal Postgres setup.
