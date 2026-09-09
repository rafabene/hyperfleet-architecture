---
Status: Active
Owner: HyperFleet Team
Last Updated: 2026-09-09
---

# 0022 — OCI Database with PostgreSQL as the Managed Instance for the Oracle Deployment Path

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
`oracle/oci` Terraform provider). This decision ([HYPERFLEET-1571](https://redhat.atlassian.net/browse/HYPERFLEET-1571))
records that choice and the settings validated live against the rhelcert
tenancy on 2026-09-09, so the next implementation story does not have to
re-derive them.

## Decision

Use **OCI Database with PostgreSQL** as the managed instance for the Oracle
deployment path. Self-managed PostgreSQL (the existing embedded Helm
sub-charts) remains the answer for local (`kind`) and dev work — this
decision does not change those environments.

### Validated settings (confirmed live against rhelcert, 2026-09-09)

- **Shape family**: `VM.Standard.E5.Flex` — flexible OCPU (1–64) and memory
  (16–1024 GB, 16 GB/OCPU default). Confirmed available in `us-sanjose-1` via
  `oci psql shape-summary list-shapes`. `VM.Standard.E6.Flex` and
  `VM.Standard3.Flex` are also offered and PostgreSQL-17-compatible, but
  `E5.Flex` is the standard current-generation flex shape and is what the
  `hyperfleet-infra` scaffolding defaults to.
- **PostgreSQL version**: **17**. Confirmed via
  `oci psql default-configuration-collection list-default-configurations`:
  version 17 has an `ACTIVE` default configuration compatible with
  `VM.Standard.E5.Flex`, `VM.Standard.E6.Flex`, and `VM.Standard3.Flex` in
  `us-sanjose-1`. (18 exists but its default configuration set is newer/less
  proven; 13–16 are older majors with no reason to prefer them for a new
  deployment.)
- **Single-availability-domain durability constraint (home region)**:
  `us-sanjose-1` — rhelcert's home region — has exactly **one** availability
  domain (confirmed via `oci iam availability-domain list`:
  `gzqB:US-SANJOSE-1-AD-1`). `oci_psql_db_system`'s `storage_details` ties
  `is_regionally_durable` and `availability_domain` together: regional
  durability (`is_regionally_durable = true`) spreads storage across multiple
  ADs and must **not** set `availability_domain`; AD-local durability
  (`is_regionally_durable = false`) requires `availability_domain` to be set
  explicitly. With only one AD available, regional durability is not a real
  option here — the db system must set `is_regionally_durable = false` and
  pin `availability_domain` to the tenancy's single AD. This is a durability
  ceiling to design around (no cross-AD storage redundancy in this region),
  not a misconfiguration to fix later.
- **Private endpoint networking**: the db system's primary endpoint is
  always a private IP inside a customer-supplied subnet
  (`network_details.subnet_id` / `primary_db_endpoint_private_ip`) — there is
  no public-endpoint option. Reachability from outside the VCN requires VCN
  connectivity such as site-to-site VPN, FastConnect, or peering, or Bastion
  port forwarding; it is not a configuration flag on the db system itself.
  (A service gateway does not apply here — it gives the VCN outbound access
  to Oracle services, not inbound access into it.)
- **Three-database layout**: every new db system ships the standard
  PostgreSQL system catalog of three databases — `postgres`, `template0`,
  `template1` — before any application database is created. HyperFleet's own
  database (e.g. `hyperfleet-api`) is created on top of that as an
  additional database, by the admin role, once the db system is live; it is
  not part of the db system's creation payload.
- **Admin role privilege boundary**: the `credentials` block's admin user is
  granted OCI's `oci_admin_role` — it can create/manage roles and users and
  enable the extensions OCI supports — but it is **not** a PostgreSQL
  `SUPERUSER`. True superuser-level operations remain reserved to an
  Oracle-internal `oci_superuser` role that owns the system databases and
  handles replication/OS-level concerns. Anything that assumes superuser
  (some `pg_dump`/`pg_restore` global objects, `NOSUPERUSER`-conditioned
  `ALTER ROLE` statements, unsupported extensions) needs to be adjusted for
  this boundary before it will run against a db system admin connection.

## Consequences

**Gains:**

- Removes patching, backup, failover, and version-upgrade ownership for the
  Oracle path's Postgres instance from HyperFleet — OCI operates the
  db system.
- Wire-compatible with the same Postgres client/driver `hyperfleet-api`
  already uses; no application-level translation layer, unlike Autonomous
  Database or Base Database Service.
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

- No cross-AD storage redundancy in `us-sanjose-1` (single AD) — an AD-level
  event takes the db system down with it. This ADR does not define backup
  retention, cross-region copy destination, restore process, or RPO/RTO for
  the Oracle path: OCI's automatic backups cap at 35 days retention, and a
  cross-region `copyPolicy` on `management_policy.backup_policy` is only
  possible from AD-specific placement (which this decision already uses,
  see the single-AD constraint above) — the `hyperfleet-infra` Terraform
  scaffolding currently defaults to a 7-day daily backup with no
  cross-region copy configured, and does not implement point-in-time
  recovery either. Backup/DR posture, ownership, and RPO/RTO targets are
  left to a future story, not decided here.
- The admin connection cannot perform superuser-only operations; any
  extension or migration step that needs `SUPERUSER` requires either an OCI
  Postgres migration guide workaround or is simply unsupported.
- Introduces a new stateful, billed OCI resource per environment that uses
  it, versus the embedded pod's zero marginal infrastructure cost.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Oracle Autonomous Database | Exadata-based, Oracle-Database-flavored (not Postgres wire-compatible) — would require a translation/compatibility layer for `hyperfleet-api`'s existing Postgres driver and SQL. Cost and operational model (Autonomous-specific tooling) are also disproportionate to a Postgres-sized workload. |
| Oracle Base Database Service (VM/BM DB systems) | Runs the Oracle Database engine, not PostgreSQL — same wire-incompatibility problem as Autonomous Database, without the serverless/autoscaling upside. |
| MySQL HeatWave on OCI | Wrong database engine entirely; `hyperfleet-api` is written against Postgres semantics (JSONB, roles/grants), not MySQL. |
| Self-managed PostgreSQL on OCI Compute (own VM) | Recreates exactly the operational burden — patching, backup, failover, upgrades — that choosing a managed service is meant to remove, while still being single-AD-limited in `us-sanjose-1`. Remains the model for local/dev, where that burden is acceptable and a managed instance would be overkill. |

## References

- [HYPERFLEET-1571](https://redhat.atlassian.net/browse/HYPERFLEET-1571) — this decision.
- `oci psql shape-summary list-shapes`, `oci psql default-configuration-collection list-default-configurations`, `oci iam availability-domain list` — live queries against the rhelcert tenancy (`us-sanjose-1`), 2026-09-09.
- [OCI Database with PostgreSQL documentation](https://docs.oracle.com/en-us/iaas/Content/postgresql/home.htm) — service overview, private-endpoint networking, admin credential management.
- [`oci_psql_db_system` (Terraform provider `oracle/oci`)](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/psql_db_system) — resource schema for `network_details`, `storage_details`, `credentials`, `management_policy`.
- [`openshift-hyperfleet/hyperfleet-infra` `terraform/oci/`](https://github.com/openshift-hyperfleet/hyperfleet-infra/tree/main/terraform/oci) — the OCI stack this decision's Terraform scaffolding (`terraform/modules/postgresql/oci/`, disabled by default) extends.
