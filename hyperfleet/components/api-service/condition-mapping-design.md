---
Status: Draft
Owner: HyperFleet API Team
Last Updated: 2026-09-29
---

# Condition Mapping Design

**Jira**: [HYPERFLEET-907](https://redhat.atlassian.net/browse/HYPERFLEET-907)

## Terminology

| Term | Definition |
|------|-----------|
| **Resource Condition** | Kubernetes-style condition in `status.conditions` array on Cluster/NodePool resources. Status is `True` or `False` in steady state. `Unknown` may appear transiently during resource initialization. Mapped conditions enforce the True/False-only contract — see **Unknown Filtering** under Rule Execution. |
| **Adapter Condition** | Condition reported by adapters via `PUT /statuses`. Status can be `True`, `False`, or `Unknown`. Stored in `adapter_statuses` table. **Note**: Adapter conditions with `status="Unknown"` are automatically filtered out during mapping and never converted to resource conditions, preventing violations of the True/False-only contract. |
| **Standard Condition Fields** | All conditions (both Resource and Adapter) contain six fields: <br>• `type` — condition category (string)<br>• `status` — `True`/`False` for resource conditions; `True`/`False`/`Unknown` for adapter conditions<br>• `reason` — machine-readable cause (CamelCase string)<br>• `message` — human-readable description<br>• `observed_generation` — resource generation when condition was set<br>• `last_transition_time` — RFC 3339 timestamp of last status change |
| **Condition Mapping** | Declarative CEL-based rules that copy/transform selected adapter conditions into resource conditions. |
| **Aggregated Conditions** | System-computed resource conditions (`Reconciled`, `LastKnownReconciled`) synthesized from adapter statuses. Only applies to reconcilable resources (Cluster, NodePool). Non-reconcilable resources (Channel, Version) have no aggregated conditions, unless a condition mapper is configured. Future: express these via custom mappings to eliminate exceptions. |
| **Mapped Conditions** | **Output of Condition Mapping** — resource conditions dynamically created from adapter conditions via the mapping rules defined above. |

## What & Why

**What**: Add a CEL-based condition mapping engine to the HyperFleet API that copies/transforms selected adapter conditions from `/statuses` endpoint into the public `status.conditions` array on Cluster and NodePool resources.

**Why**: The current `status.conditions` exposes only aggregated conditions (`Reconciled`, `LastKnownReconciled`) plus per-adapter conditions (`<AdapterName>Successful`). Rich provider-specific conditions (e.g., ROSA control plane status, GCP provider health) are only accessible via the internal `/statuses` endpoint, which is not exposed to customers.

**The Problem**: External consumers (CLI, UI, customer integrations) cannot access provider-specific cluster status. Rich provider health signals (e.g., ROSA control plane readiness, GCP quota availability) exist in adapter conditions but are not surfaced in the public API resource. Partners cannot expose provider-specific status to customers without code changes to the API aggregation logic.

**Requirements**: Partners need to expose provider-specific conditions (e.g., ROSA control plane readiness, GCP quota status) and cross-adapter aggregations (e.g., cluster health from multiple adapters) in the public API. All adapter conditions are available as input; CEL expressions filter and transform to create resource conditions. See [HYPERFLEET-907](https://redhat.atlassian.net/browse/HYPERFLEET-907) for detailed requirements from GCP and ROSA adapter teams.

**Related Documentation:**

- **Current Status Aggregation**: [ADR-0008 — Dynamic Status Aggregation](../../adrs/0008-dynamic-status-aggregation.md) — aggregation computed on write path; [ADR-0007 — Conditions-Based Status Model](../../adrs/0007-conditions-based-status-model.md) — ResourceCondition and AdapterCondition contracts; [Status Guide](../../docs/status-guide.md) — condition reporting and validation rules
- [API Service Design](./api-service.md) — API architecture and service layer patterns
- [Sentinel Decision Engine Reference](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/docs/decision-engine.md) — Existing CEL usage in Sentinel
- [Adapter Framework Design](../adapter/framework/adapter-frame-design.md) — Existing CEL usage in adapters (Config Loader and Criteria Evaluator sections)

### Scope

- CEL-based condition mapping engine in API status aggregation flow
- Configuration schema for mapping rules (all adapter conditions available as input)
- Integration into existing `AggregateResourceStatus()` function

### Out of Scope

- **New API endpoints** — mapping runs during existing `PUT /statuses` flow
- **Adapter config changes** — adapters continue reporting conditions as-is
- **Condition validation** — adapters already validate mandatory conditions (`Available`, `Applied`, `Health`)

---

## How

### Overview

The API runs condition mapping **within the existing status aggregation flow** (triggered by `PUT /statuses`). No new endpoints or components are introduced. The mapper filters and transforms adapter conditions using CEL expressions, then appends mapped conditions to the resource's `status.conditions` array.

```mermaid
flowchart TD
    A[Adapter PUTs /statuses] --> B[API stores adapter_status row]
    B --> C[Fetch all adapter_statuses for resource]
    C --> D[AggregateResourceStatus]
    D --> E[Compute aggregated conditions<br/>Reconciled, LastKnownReconciled]
    E --> F{Mapping rules configured?}
    F -->|Yes| G[Apply CEL mapping rules]
    F -->|No| H[Skip mapping]
    G --> I[Filter adapter conditions]
    I --> J[Transform type/reason/message]
    J --> K[Merge conditions optional]
    K --> L[Append mapped conditions]
    H --> L
    L --> M[Marshal all conditions to JSON]
    M --> N[Update resource.status_conditions]
    N --> O[Return 200 OK]
```

### Mapping Execution Flow

Condition mapping runs **during the existing PUT /statuses flow** — no new endpoints or components.

```mermaid
sequenceDiagram
    participant Adapter
    participant API
    participant DB
    participant Mapper
    participant Resource
    
    Note over Adapter,Resource: Adapter reports status
    Adapter->>API: PUT /statuses with conditions
    API->>DB: Store adapter_status row
    
    Note over API,Mapper: Status aggregation (existing flow)
    API->>DB: Fetch all adapter_statuses
    API->>API: Compute aggregated conditions<br/>(Reconciled, LastKnownReconciled)
    
    Note over API,Mapper: NEW: Condition mapping
    API->>Mapper: Apply mapping rules (all adapter conditions available)
    
    loop For each rule
        Mapper->>Mapper: Evaluate when expression
        Mapper->>Mapper: Compute output (type, status, reason, message)
        Mapper-->>API: Return mapped condition
    end
    
    API->>API: Append mapped conditions
    API->>DB: Update resource.status_conditions
    API->>Resource: Resource now has rich conditions
    API-->>Adapter: 200 OK
    
    Note over Resource: Public GET shows all conditions
    Resource-->>Adapter: GET /clusters/ID<br/>status.conditions includes mapped
```

**Key Points**:

- Mapping happens **on every PUT /statuses** (during existing aggregation flow)
- Unknown conditions automatically filtered out (only True/False mapped)
- Atomic transaction: adapter status + mapped conditions committed together

### Configuration Schema

Mapping rules are configured **per resource type** (clusters, nodepools) in the API's adapter requirements config. **All adapter conditions from all adapters for that resource type are available as input** to every rule. Rules use CEL expressions to filter, transform, and aggregate conditions into resource conditions. The nested `when.expression` and `output.*.expression` syntax aligns with adapter and Sentinel configurations.

```yaml
# config/hyperfleet-api.yaml

adapters:
  clusters:
    required:
      - rosa-adapter
      - gcp-adapter
    
    conditions:
      # Example 1: Copy single adapter condition with transformation
      # Map key is the output_type (target condition type)
      ROSAControlPlaneReady:
        when:
          expression: statuses.exists(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")
        output:
          status:
            expression: statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].status
          reason:
            expression: statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].reason
          message:
            expression: '"ROSA: " + statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].message'

      # Example 2: Cross-adapter aggregation (cluster health from multiple adapters)
      # Map key is the output_type (target condition type)
      ClusterHealthy:
        when:
          expression: |
            statuses.exists(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") &&
            statuses.exists(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")
        output:
          status:
            expression: statuses.filter(c, (c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") || (c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")).all(c, c.status == "True") ? "True" : "False"
          reason:
            expression: statuses.filter(c, (c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") || (c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")).all(c, c.status == "True") ? "Healthy" : "Degraded"
          message:
            expression: '"Cluster health based on ROSA control plane and GCP quota"'
      
      # Example 3: Using data fields
      # Map key is the output_type (target condition type)
      GCPQuotaStatus:
        when:
          expression: statuses.exists(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable" && c.?data.?quotaRemaining.hasValue())
        output:
          status:
            expression: statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0) > 10 ? "True" : "False"
          reason:
            expression: statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0) > 10 ? "SufficientQuota" : "LowQuota"
          message:
            expression: '"GCP quota remaining: " + string(statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0))'
```

### Rule Execution Model

Each rule executes **once per PUT /statuses request**, producing **at most one resource condition**. The execution model:

1. **Conditional evaluation**: The `when.expression` is evaluated once. If it returns `false`, the rule is skipped entirely.
2. **Output generation**: If the `when.expression` returns `true`, the `output.*.expression` fields execute to produce one resource condition.
3. **Cardinality control**: Rules use CEL expressions to decide how to handle multiple matching conditions:
   - **Single condition**: Use `statuses.filter(...)[0]` to take the first match
   - **Aggregate multiple**: Use `statuses.filter(...).all()`, `.exists()`, or `.map()` to merge signals

**Example**: A rule with `when.expression: statuses.exists(c, c.type.startsWith("GCP"))` will fire if **any** GCP condition exists, but produces only **one** output condition. The `output.status.expression` decides how to aggregate (e.g., `all(c, c.status == "True")`).

**DSL Consistency**: The nested `when.expression` and `output.*.expression` format aligns with adapter and Sentinel CEL configurations (see [Adapter Framework Design](../adapter/framework/adapter-frame-design.md)), ensuring consistent syntax across all HyperFleet components.

**Output Type**: The `type` field of the generated resource condition is derived from the **map key**. For example, a rule with key `ROSAControlPlaneReady` produces a condition with `type: "ROSAControlPlaneReady"`.

**Generated Fields**: Rules specify three output fields via `output.status.expression`, `output.reason.expression`, and `output.message.expression`. Three additional fields are **automatically generated** by the API:

- `type` — set to the map key (e.g., `ROSAControlPlaneReady`)
- `observed_generation` — set to `resourceGeneration` (current resource generation)
- `last_transition_time` — set to current server timestamp when the condition is first created. On subsequent updates, only updated if `status` changes (matches Kubernetes condition semantics)

### Rule Execution and Conflict Resolution

**Evaluation Order**: Rules are stored in a map where the **key is the output condition type**. Map iteration order is **undefined** — rules may execute in any order. Since each map key is unique, there is no possibility of overlap or conflict between rules.

**No Conflict Resolution Needed**: Because the map key **is** the output condition type, each rule produces exactly one unique condition. There is no need for a "last-wins" strategy or priority ordering.

**Unknown Filtering**: Adapter conditions with `status="Unknown"` are **automatically filtered out** before CEL evaluation. Only conditions with `status="True"` or `status="False"` are available in the `statuses` variable, ensuring resource conditions never violate the True/False-only contract.

### CEL Evaluation Context

All rule CEL expressions have access to the same context:

**Variables Available**:

- `statuses` — array of all adapter statuses for a resource. Each status includes:
  - `adapter` (string, e.g., `"rosa-adapter"`)
  - `type` (string)
  - `status` (`"True"` or `"False"`)
  - `reason` (string)
  - `message` (string)
  - `observed_generation` (int64)
  - `last_transition_time` (timestamp)
  - `data` (map, adapter-specific JSONB) — **Use with caution**: May contain sensitive information. Operators are responsible for ensuring mapping rules do not expose sensitive data to external consumers.
- `resource` — full resource object with access to:
  - `resource.metadata.*` — resource metadata (name, labels, annotations, etc.)
  - `resource.spec.*` — desired state specification
  - `resource.generation` — current resource generation number (alias: `resourceGeneration`)
- `env` — environment variables map (e.g., `env.ENVIRONMENT`, `env.CLUSTER_REGION`) for environment-specific mapping logic

**Safe Navigation Pattern** (HyperFleet CEL Standard):

When accessing optional/nested fields (like `data`), use the **safe navigation operator (`?`)** to prevent errors:

| Pattern | Example | Behavior |
|---------|---------|----------|
| ❌ **Unsafe** | `has(c.data.quotaRemaining)` | Fails with error if `data` field doesn't exist |
| ✅ **Safe (check)** | `c.?data.?quotaRemaining.hasValue()` | Returns `false` if `data` or `quotaRemaining` missing; `true` if present |
| ✅ **Safe (access)** | `c.?data.?quotaRemaining.orValue(0)` | Returns `0` if missing; actual value otherwise |

**Why**: The optional `?` operator safely accesses maps without errors on missing keys. Combined with `hasValue()` (for existence checks) and `orValue(default)` (for safe access with defaults), this pattern handles all states: key missing, key with nil value, key with value.

**Reference**: See [Adapter Framework — CEL resource presence pattern](../adapter/framework/lifecycle/adapter-lifecycle-delete-design.md#example-task-config-with-deletion) for detailed rationale on why `has()` and direct access are unsafe.

**Field Allowlist**: All condition fields are exposed to CEL, including the six standard fields (`type`, `status`, `reason`, `message`, `observed_generation`, `last_transition_time`), `adapter`, and `data` (adapter-specific JSONB). **Operator Responsibility**: The `data` field may contain sensitive information (API tokens, internal IPs, credentials). Operators configuring mapping rules are responsible for ensuring that sensitive data is not exposed to external consumers via mapped conditions. Use safe navigation (`c.?data.?field.hasValue()` / `orValue(default)`) when accessing optional fields. Test mapping rules thoroughly in non-production environments before deploying to production.

### Integration Point

The mapper integrates into the existing `AggregateResourceStatus()` service layer function (see `hyperfleet-api/pkg/services/aggregation.go`). The integration point is after aggregated conditions are computed and before marshaling to JSON:

1. Fetch adapter_statuses from DB
2. Compute aggregated conditions (`Reconciled`, `LastKnownReconciled`)
3. **NEW**: Apply condition mapping (if configured)
4. Marshal all conditions to JSON
5. Update resource.status_conditions

Mapped conditions are included in the same database transaction as the adapter status update via the existing transaction-per-request middleware in `hyperfleet-api/pkg/db`. The transaction encompasses both the adapter status write and the resource status_conditions update, ensuring atomicity — either both operations succeed or both are rolled back.

### Error Handling and Validation

**Field Validation**: Before CEL evaluation, the mapper validates adapter condition fields to prevent injection and resource exhaustion:

| Field | Max Length | Enforcement | Behavior on Violation |
|-------|------------|-------------|----------------------|
| `type` | 128 chars | Compile-time (adapter PUT) | Condition rejected during `PUT /statuses` |
| `reason` | 256 chars | Runtime (pre-CEL) | Condition skipped, warning logged |
| `message` | 2048 chars | Runtime (pre-CEL) | Message truncated, warning logged |
| `status` | Must be True/False/Unknown | Compile-time (adapter PUT) | Condition rejected during `PUT /statuses` |

**Validation Behavior Rationale**: The `reason` field is **machine-readable** and used in CEL expressions and Sentinel decision logic — invalid or oversized reasons could break filtering logic, so the entire condition is skipped. The `message` field is **human-readable** and informational only — truncation preserves the first 2048 characters without breaking semantics, allowing the condition to remain usable for automation.

**CEL String Operation Limits**: Even if a CEL transformation expression attempts to generate a message exceeding 2048 characters, the CEL runtime's **100KB string limit and 10MB memory limit** (documented in Security Considerations § 1) prevent memory exhaustion during evaluation. Expressions exceeding these bounds abort evaluation, the condition is skipped, and an error is logged.

**JSON Unmarshaling**: If stored adapter conditions are malformed (corrupted JSONB, schema mismatch), the mapper logs a warning and excludes those conditions from the `statuses` array. All mapping rules are still evaluated with the valid subset of conditions.

**CEL Evaluation Errors**: If a CEL expression fails (type mismatch, undefined variable, null reference), the entire mapping operation fails and the database transaction is **rolled back**. The adapter receives an error response, and the status update is retried on the next reconciliation cycle (typically 10 seconds). This ensures the system remains consistent — either all adapter status and mapped conditions are committed together, or none are committed. **Rationale**: Accepting partial mapping results (committing adapter status without mapped conditions) would prevent timely retry — if the last required adapter reports `Available: True` but mapping fails, committing would incorrectly set `Reconciled: True` and delay the next reconcile attempt from 10 seconds to 30 minutes.

---

## Security Considerations

Condition mapping processes operator-controlled configuration and exposes adapter-reported data to external consumers. Five security domains require explicit safeguards:

### 1. CEL Expression Validation and Sandboxing

**Compile-Time Checks**: All CEL expressions are **compiled at API server startup** (fail-fast). Invalid syntax, undefined variables, or type mismatches prevent the server from starting.

**Complexity Limits** (CEL library defaults):

- **AST Node Limit**: Maximum **1000 AST nodes** — prevents excessively large expressions
- **Expression Depth**: Maximum **32 levels of nesting** — prevents stack exhaustion
- **String Length**: Maximum **100KB per string literal** — prevents memory exhaustion

**Runtime Safeguards**:

- **Memory Limit**: Maximum **10MB allocation per expression** (CEL library enforced)
- **Recursion Limit**: CEL disallows recursive function calls — prevents stack overflow
- **Sandboxing**: CEL runtime cannot execute arbitrary code, access filesystem/network, or modify global state

### 2. Adapter Condition Data Exposure Risks

**Data Field Exposure**: The `data` field (adapter-specific JSONB) is exposed to CEL expressions to provide maximum flexibility for partners. This field may contain sensitive information (API tokens, internal IPs, credentials, internal resource IDs).

**Operator Responsibility**: Operators configuring mapping rules are **solely responsible** for ensuring that sensitive data from the `data` field is not exposed to external consumers via mapped conditions. This includes:

- **Testing in non-production environments** — validate mapping rules do not leak sensitive data before deploying to production
- **Reviewing adapter `data` schemas** — understand what data adapters store in the `data` field
- **Auditing mapped conditions** — verify mapped conditions only expose customer-visible status, not internal implementation details
- **Using CEL filtering** — use CEL expressions to selectively extract non-sensitive fields from `data` (e.g., `statuses.filter(...)[0].?data.?publicField.orValue("")` instead of exposing the entire `data` object)

**Adapter Responsibility**: Adapters MUST follow the [Error Model Standard](../../standards/error-model.md) when populating `type`, `reason`, and `message` fields. These fields are exposed to external consumers via mapped conditions and MUST NOT contain:

- Internal service URLs or IP addresses
- Stack traces or debug information
- Sensitive configuration values (tokens, credentials, internal resource IDs)
- Implementation details that leak internal architecture

**Best Practice**: Adapters should use dedicated condition types with structured `type`, `reason`, and `message` fields for customer-visible status. The `data` field should be used for internal adapter state that requires careful operator review before mapping.

### 3. Access Control

**Configuration Changes**: Condition mapping rules are defined in the API's YAML configuration file, which requires **cluster-admin RBAC permissions** to modify (Kubernetes ConfigMap or file on disk). Rule changes require API server restart.

### 4. Error Sanitization

**RFC 9457 Compliance**: Mapping errors returned to adapters (via `PUT /statuses` response) follow RFC 9457 Problem Details format (see [Error Model Standard](../../standards/error-model.md)). Error messages MUST NOT leak internal details (stack traces, database connection strings, internal service names).

**Audit Logging**: Mapping execution errors (CEL timeouts, field validation failures, cardinality violations) are logged with adapter name, rule name, and error reason per the [Logging Standard](../../standards/logging-specification.md).

---

## Examples

### Example 1: Copy Single Adapter Condition with Transformation

**Config:**

```yaml
ROSAControlPlaneReady:  # Map key is the output condition type
  when:
    expression: statuses.exists(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")
  output:
    status:
      expression: statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].status
    reason:
      expression: statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].reason
    message:
      expression: '"ROSA: " + statuses.filter(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady")[0].message'
```

**Input** (adapter condition from rosa-adapter):

```json
{"adapter": "rosa-adapter", "type": "ControlPlaneReady", "status": "True", "reason": "Operational", "message": "Control plane is operational", "observed_generation": 5, "last_transition_time": "2026-05-19T10:30:00Z"}
```

**Output** (resource condition - observed_generation and last_transition_time auto-generated):

```json
{"type": "ROSAControlPlaneReady", "status": "True", "reason": "Operational", "message": "ROSA: Control plane is operational", "observed_generation": 5, "last_transition_time": "2026-05-19T10:32:00Z"}
```

### Example 2: Cross-Adapter Aggregation

**Config:**

```yaml
ClusterHealthy:  # Map key is the output condition type
  when:
    expression: |
      statuses.exists(c, c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") &&
      statuses.exists(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")
  output:
    status:
      expression: statuses.filter(c, (c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") || (c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")).all(c, c.status == "True") ? "True" : "False"
    reason:
      expression: statuses.filter(c, (c.adapter == "rosa-adapter" && c.type == "ControlPlaneReady") || (c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")).all(c, c.status == "True") ? "Healthy" : "Degraded"
    message:
      expression: '"Cluster health based on ROSA control plane and GCP quota"'
```

**Input** (conditions from rosa-adapter and gcp-adapter):

```json
[
  {"adapter": "rosa-adapter", "type": "ControlPlaneReady", "status": "True", "reason": "Operational", "message": "Control plane is operational", "observed_generation": 5, "last_transition_time": "2026-05-19T10:30:00Z"},
  {"adapter": "gcp-adapter", "type": "QuotaAvailable", "status": "False", "reason": "QuotaExceeded", "message": "GCP quota exceeded", "observed_generation": 5, "last_transition_time": "2026-05-19T10:28:00Z"}
]
```

**Output** (cross-adapter aggregated condition - observed_generation and last_transition_time auto-generated):

```json
{"type": "ClusterHealthy", "status": "False", "reason": "Degraded", "message": "Cluster health based on ROSA control plane and GCP quota", "observed_generation": 5, "last_transition_time": "2026-05-19T10:32:00Z"}
```

### Example 3: Using `data` Field Safely

**Config:**

```yaml
GCPQuotaDetails:  # Map key is the output condition type
  when:
    expression: statuses.exists(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable" && c.?data.?quotaRemaining.hasValue())
  output:
    status:
      expression: statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0) > 10 ? "True" : "False"
    reason:
      expression: statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0) > 10 ? "SufficientQuota" : "LowQuota"
    message:
      expression: '"GCP quota remaining: " + string(statuses.filter(c, c.adapter == "gcp-adapter" && c.type == "QuotaAvailable")[0].?data.?quotaRemaining.orValue(0))'
```

**Input** (adapter condition from gcp-adapter with `data` field):

```json
{"adapter": "gcp-adapter", "type": "QuotaAvailable", "status": "True", "reason": "Available", "message": "Quota is available", "observed_generation": 5, "last_transition_time": "2026-05-19T10:30:00Z", "data": {"quotaRemaining": 25, "internalProjectId": "secret-12345"}}
```

**Output** (resource condition - only non-sensitive field extracted from `data`):

```json
{"type": "GCPQuotaDetails", "status": "True", "reason": "SufficientQuota", "message": "GCP quota remaining: 25", "observed_generation": 5, "last_transition_time": "2026-05-19T10:32:00Z"}
```

**Security Note**: This example shows selective extraction using safe navigation — the CEL expression `c.?data.?quotaRemaining.hasValue()` safely checks field presence and `orValue(0)` provides a safe default. This extracts only `quotaRemaining` (customer-visible) and ignores `internalProjectId` (sensitive). Operators must use the safe navigation pattern (`c.?data.?field.hasValue()` / `orValue(default)`) to prevent errors when fields are missing and carefully review which `data` fields are exposed.

---

## Trade-offs

### What We Gain

- **Declarative exposure** — adapters add new conditions without code changes
- **Consistent API design** — all status in `status.conditions`, no internal `/statuses` dependency
- **CEL consistency** — reuses existing pattern from Sentinel and adapters
- **Cross-adapter aggregation** — partners can create conditions aggregating signals from multiple adapters (e.g., cluster health from ROSA + GCP)
- **Simpler design** — single rule format, all adapter conditions always available (no 1-to-1 vs N-to-1 distinction)
- **Sentinel simplification** — decision expressions read resource conditions directly (no `/statuses` fetch)
- **External consumer access** — CLI, UI, integrations see provider-specific conditions
- **Cardinality control** — operators configure exactly which conditions to expose (prevents bloat)
- **No conflict resolution needed** — map keys guarantee unique output types, eliminating the need for last-wins strategy or priority ordering
- **Self-documenting** — map key explicitly declares the output condition type, improving readability
- **Maximum flexibility** — `data` field exposure allows partners to extract structured adapter-specific information for custom condition logic without requiring API changes

### What We Lose / What Gets Harder

- **API latency** — CEL evaluation adds per-resource overhead (actual performance to be measured during implementation)
- **Configuration complexity** — operators must write CEL expressions (mitigated by examples and validation)
- **Debugging** — mapping failures require checking API logs, not visible in adapter response
- **Tight coupling** — API config must know adapter condition naming (adapters can't change condition types without coordinating config updates)
- **Security risk** — exposing `data` field increases risk of leaking sensitive information (API tokens, credentials, internal IPs) if operators misconfigure mapping rules. Operators must thoroughly test rules in non-production environments and audit mapped conditions before production deployment.

### Technical Debt Incurred

- **No CEL evaluation timeouts** — MVP does not implement per-expression or aggregate timeouts. CEL expressions that run indefinitely (e.g., infinite loops in complex filters) will block the request. Deferred until adoption patterns are known and typical CEL complexity is understood. When implemented, timeouts must trigger transaction rollback (not partial commits) to ensure timely retry on next reconciliation cycle.
- **No adapter re-reporting optimization** — for large clusters, repeated status updates generate mapping overhead proportional to Sentinel polling frequency (deferred)
- **Mapper-only kinds never reconcile** — computing `Reconciled` requires at least one required adapter to report success. A Sentinel watching such a kind would republish it on every poll once the 10s debounce has passed, indefinitely (see [Sentinel — Key Insight](../sentinel/sentinel.md#decision-logic)). No entity combines a mapper with zero required adapters today; operators should not combine condition mapping with an empty `required_adapters` list.

### Acceptable Because

- CEL evaluation latency overhead is expected to be negligible compared to 200ms baseline API response time (actual performance measured during implementation)
- CEL is already required for Sentinel and adapters — no new dependency
- Debugging mapping failures is rare (fail-fast at startup catches most issues)
- Adapter condition naming stability is expected (breaking changes require coordination anyway)
- MVP focuses on unblocking Sentinel and external consumers; optimization follows
- Security risk of exposing `data` field is acceptable because: (1) mapping config requires cluster-admin RBAC permissions (see Access Control § 3), preventing unauthorized changes; (2) operators are expected to test rules in non-production environments before deploying; (3) partners need flexibility to extract adapter-specific structured data without waiting for API changes; (4) restricting `data` access would force partners to report duplicate information via dedicated condition types, increasing adapter complexity
- No timeouts in MVP is acceptable because: (1) mapping rules are operator-controlled configuration validated at startup — malicious or broken expressions are caught before deployment; (2) adoption patterns and typical CEL complexity are unknown — premature optimization; (3) CEL library limits (1000 AST nodes, 32 nesting levels) prevent most pathological cases; (4) timeouts can be added later based on production metrics if needed

---

## Alternatives Considered

### 1. Go Templates

**What**: Use Go's `text/template` for transformation logic instead of CEL.

**Why Rejected**: Go templates lack sandboxing (can execute arbitrary functions), type safety, and expression libraries (filters, map/reduce). CEL is already a project dependency and provides compile-time validation.

### 2. Static YAML Mapping

**What**: Hardcode simple condition name mappings in YAML without expressions:

```yaml
mappings:
  rosa-adapter:
    ControlPlaneReady: ROSAControlPlaneReady
```

**Why Rejected**: Cannot support aggregations (e.g., `GCPProviderHealthy` from multiple conditions), message transformations, cross-adapter aggregation, or conditional logic. Too inflexible for adapter requirements.

### 3. Adapter-Side Mapping

**What**: Adapters report both internal conditions (`data` field) and public conditions (`status.conditions`-ready format) in the same `PUT /statuses` call.

**Why Rejected**: Duplicates mapping logic across all adapters. Adapters must know HyperFleet condition naming conventions. Makes adapters less reusable across platforms.

---

## References

- [HYPERFLEET-907](https://redhat.atlassian.net/browse/HYPERFLEET-907) — SPIKE: Design declarative condition mapping mechanism
- [HYPERFLEET-905](https://redhat.atlassian.net/browse/HYPERFLEET-905) — Parent epic: Expose API resource statuses through status.conditions
- [ADR-0008 — Dynamic Status Aggregation](../../adrs/0008-dynamic-status-aggregation.md)
- [ADR-0007 — Conditions-Based Status Model](../../adrs/0007-conditions-based-status-model.md)
- [Status Guide](../../docs/status-guide.md)
- [Error Model Standard](../../standards/error-model.md)
- [Logging Standard](../../standards/logging-specification.md)
- [Sentinel Decision Engine Reference](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/blob/main/docs/decision-engine.md)
- [Adapter Framework Design](../adapter/framework/adapter-frame-design.md)
