---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-30
---

# 0027 — Mixed Tenant Dimension Cardinality: Owner-Inherited Child Tenancy and an Unscoped Referencer Check

## Context

HyperFleet scopes reads and lists by JSONB containment, which is asymmetric: a caller with fewer tenant dimensions matches a resource with more, never the reverse. Both shipped tenant models mark their second dimension `required: false`, so an org-scoped caller (`{org}`) and a project-scoped caller (`{org, project}`) can coexist. A containment-scoped guard on the delete path then misses resources outside the deleting caller's scope, in two ways.

A referencer can sit in a broader or sibling scope. Reference targets are resolved with the reference-creating caller's scope, which only requires the caller's map to be contained in the target's map; a project-scoped user deletes a WifConfig that an org-scoped user's cluster references, and a scoped check never sees that cluster. The reference is foreign-key-protected, so the row is not left dangling — the delete fails instead: a hard delete returns `500` with the raw foreign-key error, and a soft delete leaves the resource stuck in `Finalizing` because the hard-delete step fails on every adapter report.

A child can carry a different tenancy than its parent, because a child is currently stamped with the creating caller's tenancy. An org-scoped caller adds a NodePool to a project-scoped cluster; the NodePool records `{org}`, and a project-scoped delete of the cluster walks its children containment-scoped, misses it, and deletes the cluster anyway. `owner_id` has no foreign key, so the child is silently orphaned with its infrastructure never torn down.

## Decision

Mixed tenant dimension cardinality is supported: the "broader scope sees narrower resources" behavior is a designed capability of the containment model, not an accidental shape.

A child resource inherits its parent's tenancy map instead of the creating caller's, so an owner and its children never differ. A caller can only see an owner whose map contains the caller's, so the owner's map is always a superset; stamping the child with it isolates the child to exactly the owner's extent and makes its isolation genuinely transitive through the owner.

Delete-path integrity checks are therefore split by what they compare. Child checks — `ExistsByOwner`, `ExistsSoftDeletedByOwner`, the `deleteResourceTree` cascade listing, and the `forceDeleteResourceTree` tree walk — compare a child to its owner and stay containment-scoped: with identical maps, a scoped lookup is exact. The referencer check (`FindReferencers`) compares a referencer to the deleted resource and runs unscoped, so nothing can be deleted while any resource in the deployment references it. Force-delete is unscoped in its reference handling too: it bypasses the referencer restriction and clears a resource's inbound references before hard-deleting it, so a hard delete is not blocked by a referencer the caller cannot see.

The resulting `409` names a referencer the caller can see and genericizes one it cannot, so it never discloses an identity the caller cannot see; it still discloses that an out-of-scope referencer exists, and it carries a fixed, machine-readable reason code so a caller can branch without parsing the message. This narrows the baseline `409` contract in the generic resource registry design to referencers the caller can see.

A referencer is not confined to the deleted resource's scope or a broader one: because targets are validated with the reference-creating caller's scope only, a referencer can sit in a sibling scope (an org-scoped caller points a `{org, p1}` child at a `{org, p2}` target). The check must therefore stay unscoped; narrowing it to the caller's scope, or to same-or-broader scopes, reopens the hole for sibling projects.

Read, list, and update scoping is unchanged, and single-dimension deployments are a degenerate case of the same rule.

## Consequences

**Gains:**

- Org-wide visibility survives without special-casing or a separate admin mechanism.
- Child isolation is exact and transitive; no child path needs an unscoped query, and a scoped cascade cannot orphan an out-of-scope child.
- The referencer check and force-delete's inbound-reference handling are deliberately unscoped and are named here so no future change scopes them back; every child check stays containment-scoped.

**Trade-offs:**

- The referencer query and force-delete's inbound-reference handling are intentionally not tenant-scoped: the referencer query can surface a sibling-scope referencer, and force-delete clears inbound references held by resources the caller cannot see. Every future referencer or reference-clearing check must opt in, and a scoped or same-or-broader check added later would silently reintroduce the hole.
- Child rows created before this rule carry the creating caller's tenancy and need a backfill; HyperFleet is pre-production, so no production migration strategy is required.
- The `409` loses precise referencer detail for out-of-scope resources; operators rely on the reason code.
- Mixed cardinality retains the documented uniqueness-versus-visibility mismatch (a broader and a narrower caller can each create the same name and both see duplicates). This decision neither introduces nor resolves it.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Same cardinality always: config validation rejects any `server.tenant.dimensions` entry with `required: false` | Prevents the mixed shape but removes the org-wide visibility the containment model exists to provide, forcing every caller in a deployment to carry the full dimension set and leaving no way for an org-scoped caller to see a project's resources. |
| Keep mixed cardinality and rely on the operational rule that nobody issues org-only tokens | That is an assumption, not an invariant. The shipped on-prem and OCI models enable the shape by configuration, so nothing enforces the rule. |
| Run every delete-path query unscoped, including the child cascade and the force-delete tree walk | Turns a project-scoped delete into an unscoped write over an org user's child tree — a mutation of a resource the caller cannot see — and still silently skips an out-of-scope child whose kind has no required adapters, deleting the parent and orphaning the child's infrastructure. Inheriting the owner's tenancy removes the out-of-scope child case instead of widening the write scope. |
| Enforce integrity at the database with row-level security | RLS governs which rows a caller may access; it does not make a referencer outside the caller's scope visible to a scoped integrity check. The defect is query scope, not access control. |
| Leave delete-path checks scoped and document the failure mode only | Documents a failure that a different caller experiences as a `500` or a resource stuck in `Finalizing`, and an orphaned child whose infrastructure is never torn down, instead of preventing it. |

## References

- [HYPERFLEET-1634: Decide and enforce tenant dimension cardinality for delete-path integrity checks](https://redhat.atlassian.net/browse/HYPERFLEET-1634)
- [Multi-Tenant Identity and Authorization Design](../docs/multi-tenant-identity-authz-design.md)
- [Generic Resource Registry Design: delete model and reference restriction](../docs/generic-resource-registry-design.md#93-deletion-restriction)
- [ADR-0020: Envoy and Authorino as the API Authentication Gateway](0020-envoy-authorino-api-gateway.md)
- [HYPERFLEET-1470: Scope all resource DAO access by tenancy containment](https://redhat.atlassian.net/browse/HYPERFLEET-1470)
- [HYPERFLEET-1473: Tenant-scoped resource name uniqueness](https://redhat.atlassian.net/browse/HYPERFLEET-1473)
