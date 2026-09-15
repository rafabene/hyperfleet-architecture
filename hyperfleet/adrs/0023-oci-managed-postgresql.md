---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-09-09
---

# 0023 — OCI Database with PostgreSQL as the Managed Instance for the Oracle Deployment Path

## Context

HyperFleet's Postgres-backed component, `hyperfleet-api`, currently runs as
a self-managed, embedded PostgreSQL pod in every environment — there is no
managed database anywhere in the stack yet. That embedded model is fine for
local (`kind`) and dev work, but the Oracle deployment path — HyperFleet's
own OKE-based build, dev, and e2e infrastructure in the rhelcert tenancy
([`hyperfleet-infra`](https://github.com/openshift-hyperfleet/hyperfleet-infra)'s
`terraform/oci`, the same stack [HYPERFLEET-1574](https://redhat.atlassian.net/browse/HYPERFLEET-1574)
built the CI compartment in) — needs a durable, operator-relieving answer
for where that state lives once the workload is more than an ephemeral e2e
run.

This is HyperFleet's own infrastructure, not a partner's: it is out of
scope of [ADR-0019](0019-package-hyperfleet-as-operator.md)'s "the operator
consumes a partner-provided Postgres; it does not provision Postgres"
boundary, which governs how `hyperfleet-operator` is configured in a
partner's environment. This decision does not change that boundary or
provision Postgres on a partner's behalf.

Oracle Cloud Infrastructure offers several database services; only one is
Postgres-wire-compatible without a translation layer: **OCI Database with
PostgreSQL** (the `oci psql` CLI namespace, `oci_psql_db_system` in the
`oracle/oci` Terraform provider).

## Decision

Use **OCI Database with PostgreSQL** as the managed instance for the Oracle
deployment path. Self-managed PostgreSQL (the existing embedded Helm
sub-charts) remains the answer for local (`kind`) and dev work — this
decision does not change those environments.

### Configuration for Oracle deployment

The `hyperfleet-infra` Terraform scaffolding defaults to:

- **Shape**: `PostgreSQL.VM.Standard.E5.Flex` (flexible OCPU and memory)
- **PostgreSQL version**: 17 (latest stable major with active OCI support)
- **Availability domain**: pinned to the tenancy's available domain in
  `us-sanjose-1` (constraints detailed in Trade-offs below)
- **Private networking**: endpoint is always private; VCN connectivity
  (site-to-site VPN, FastConnect, peering, or Bastion) required for external
  access
- **Three application databases**: `hyperfleet-api`, River (queue), and the
  desire store, each with independent per-table `autovacuum` tuning
  (PostgreSQL does not support per-database autovacuum configuration). These
  are created after the db system goes live. _Note: the current `hyperfleet-api`
  Helm chart exposes only one database connection; connecting River and the
  desire store to separate databases requires coordinated changes to the chart,
  external Secret schema, and application connection logic. This layout is
  documented as the intended state; implementation ownership is tracked
  separately_
- **Admin role privilege boundary**: the `credentials` block's admin user is
  granted OCI's `oci_admin_role` — it can create/manage roles and users and
  enable the extensions OCI supports — but is **not** a PostgreSQL
  `SUPERUSER`. Oracle-internal `oci_superuser` role handles replication
  and OS-level concerns. Migration tooling (e.g., `pg_dumpall`) needs adjustment
  for this boundary

## Consequences

**Gains:**

- Removes patching, failover, and version-upgrade operational burden for the
  Oracle path's Postgres instance from HyperFleet — OCI operates the
  db system. HyperFleet retains responsibility for backup policy, restore
  validation, RPO/RTO targets, and application upgrade coordination.
- Wire-compatible with the same Postgres client/driver `hyperfleet-api`
   already uses; no application-level translation layer, unlike Autonomous
   Database or Base Database Service. Supports LISTEN/NOTIFY for queue-like
   workloads (River, future async patterns).
- The three-database layout and admin-role boundary are close enough to
  ordinary self-hosted Postgres administration that a migration path is
  plausible. This ADR does not define HyperFleet's dump/restore tooling for
  the Oracle path, though: Oracle's documented `pg_dumpall`-based import
  path additionally requires `--no-tablespaces` (OCI Database with
  PostgreSQL only supports in-place tablespaces) on top of stripping the
  superuser-only role attributes called out above — whichever tooling
  HyperFleet settles on needs to account for both, not just the superuser
  boundary.

**Trade-offs:**

- Introduces a new stateful, billed OCI resource per environment that uses
  it, versus the embedded pod's zero marginal infrastructure cost.
- Backup/disaster-recovery posture (cross-region standby, RPO/RTO targets,
  restore ownership) are out of scope for this decision and deferred to a
  separate ticket.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Oracle Autonomous Database | Exadata-based, Oracle-Database-flavored (not Postgres wire-compatible) — would require a translation/compatibility layer for `hyperfleet-api`'s existing Postgres driver and SQL. Cost and operational model (Autonomous-specific tooling) are also disproportionate to a Postgres-sized workload. |
| Oracle Base Database Service (VM/BM DB systems) | Runs the Oracle Database engine, not PostgreSQL — same wire-incompatibility problem as Autonomous Database, without the serverless/autoscaling upside. |
| MySQL HeatWave on OCI | Wrong database engine entirely; `hyperfleet-api` is written against Postgres semantics (JSONB, roles/grants), not MySQL. |
| Self-managed PostgreSQL on OCI Compute (own VM) | Recreates exactly the operational burden — patching, backup, failover, upgrades — that choosing a managed service is meant to remove, while still being single-AD-limited in `us-sanjose-1`. Remains the model for local/dev, where that burden is acceptable and a managed instance would be overkill. |

## References

- `oci psql shape-summary list-shapes`, `oci psql default-configuration-collection list-default-configurations`, `oci iam availability-domain list` — live queries against the rhelcert tenancy (`us-sanjose-1`), 2026-09-09.
- [OCI Database with PostgreSQL documentation](https://docs.oracle.com/en-us/iaas/Content/postgresql/home.htm) — service overview, private-endpoint networking, admin credential management.
- [`oci_psql_db_system` (Terraform provider `oracle/oci`)](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/psql_db_system) — resource schema for `network_details`, `storage_details`, `credentials`, `management_policy`.
- `openshift-hyperfleet/hyperfleet-infra` repository, `terraform/oci/` directory and `terraform/modules/postgresql/oci/` subdirectory — Terraform scaffolding for this decision (disabled by default).
