# Pull Secret Service for HyperFleet Architecture

**Metadata**:
- **Date**: Nov 14, 2025
- **Status**: Draft
- **Status changed date**: Nov 17, 2025
- **Status changed reason**: Initial draft for review
- **SRE Domain**: None
- **Authors**: Leonardo Dorneles, Tirth Chetan Thakkar
- **Sponsor**: Mark Turansky
- **Supersedes**: N/A (New service)
- **Superseded By**: N/A
- **Governing ADR(s)**: N/A
- **Tickets**: [HYPERFLEET-162](https://issues.redhat.com/browse/HYPERFLEET-162)
- **Other docs**:
  - https://github.com/openshift-hyperfleet/architecture
  - [Pull Secret Workflow Implementation](./pullsecret-workflow-implementation.md)
  - [GCP Secret Manager SDK Methods](./gcp-secret-manager-sdk-methods.md)
  - [Pull Secret Requirements](./pull-secret-requirements.md)

---

## Executive Summary

The Pull Secret Adapter is responsible for securely storing and managing image registry pull secrets in GCP Secret Manager for HyperShift-managed OpenShift clusters. These secrets enable cluster nodes to pull container images from authenticated registries (e.g., Red Hat registries, Quay.io).

The service operates as an event-driven adapter within the HyperFleet architecture, consuming CloudEvents from Sentinel and orchestrating two critical workflows: (1) storing pull secrets in the customer's GCP Secret Manager for worker node access, and (2) provisioning Kubernetes secrets in the management cluster for HyperShift control plane access.

---

## What

### Service Overview

The Pull Secret Service is an event-driven adapter that manages the complete lifecycle of image registry pull secrets for HyperShift-managed OpenShift clusters provisioned on Google Cloud Platform (GCP).

### Core Responsibilities

1. **GCP Secret Manager Storage**
   - Store pull secret credentials in customer's GCP Secret Manager
   - Create secret resources with proper labels and metadata
   - Manage secret versions and updates
   - Verify secret accessibility and readiness

2. **Kubernetes Secret Provisioning**
   - Create Kubernetes Secrets in management cluster namespaces
   - Provide pull secrets for HyperShift control plane components
   - Update secrets when pull secret data changes
   - Maintain proper labels and annotations for lifecycle management

3. **Status Reporting**
   - Report adapter status to HyperFleet API
   - Provide detailed condition information (Applied, Available, Health)
   - Include metadata about secret locations and versions
   - Enable Sentinel decision-making for workflow progression

### Architecture Components

| Component | Type | Purpose |
|-----------|------|---------|
| **Pull Secret Adapter** | Deployment | Consumes events, orchestrates jobs, reports status |
| **Pull Secret Job** | Job | Executes GCP API calls and K8s secret operations |
| **GCP Secret Manager** | External Service | Stores pull secret data in customer's project |
| **Kubernetes Secret** | Resource | Provides pull secret to HyperShift |

### Integration Points

- **Upstream**: Sentinel Service (event producer)
- **Downstream**: HyperFleet API (status consumer)
- **External**: GCP Secret Manager API (customer's project)
- **Internal**: Kubernetes API (management cluster)
- **Dependencies**: Validation, DNS, Placement adapters (must complete first)

### Technology Stack

- **Language**: Go 1.21+
- **SDK**: Google Cloud Secret Manager Go SDK (`cloud.google.com/go/secretmanager`)
- **Authentication**: Workload Identity (GCP)
- **Container**: UBI8-minimal base image
- **Deployment**: Kubernetes Deployment + Job pattern

---

## Why

### Goals

#### G1: Secure Pull Secret Storage in Customer's GCP Project

**Objective**: Store pull secrets in customer's GCP Secret Manager with proper access controls and encryption.

**Success Metrics**:
- 100% of pull secrets stored in customer's GCP project (not Red Hat's)
- Secrets encrypted at rest using GCP-managed or customer-managed keys
- All secret operations logged in customer's Cloud Audit Logs
- Zero exposure of pull secret data in adapter logs or metrics

**Rationale**:
- Customer data sovereignty: Customers maintain full control over sensitive credentials
- Compliance: Meets regulatory requirements for data residency
- Security: Leverages GCP's robust secret management infrastructure
- Auditability: Complete audit trail in customer's environment

#### G2: Enable HyperShift Control Plane Access to Pull Secrets

**Objective**: Provide pull secrets to HyperShift control plane running in management cluster.

**Success Metrics**:
- Kubernetes Secrets created in correct management cluster namespace
- Secrets accessible by HyperShift HostedCluster resources
- Proper type annotation (`kubernetes.io/dockerconfigjson`)
- Zero downtime during secret updates

**Rationale**:
- HyperShift control plane needs pull secrets to provision worker nodes
- Control plane components need to pull Red Hat container images
- Separation of control plane (Red Hat) and data plane (customer) secrets

#### G3: Automation and Event-Driven Workflow

**Objective**: Fully automate pull secret provisioning as part of cluster creation workflow.

**Success Metrics**:
- Zero manual intervention required for pull secret provisioning
- Event-driven triggers from Sentinel
- Idempotent operations (safe to retry)
- Average provisioning time < 30 seconds

**Rationale**:
- Reduces operational overhead
- Eliminates human error in secret management
- Scales to thousands of clusters
- Integrates seamlessly with HyperFleet orchestration

#### G4: Cross-Project Authentication via Workload Identity

**Objective**: Enable secure authentication from Red Hat's infrastructure to customer's GCP project.

**Success Metrics**:
- No GCP service account keys stored in Red Hat infrastructure
- Workload Identity bindings documented and automated
- Token exchange transparent to operators
- Authentication failures clearly reported

**Rationale**:
- Best practice: Eliminate long-lived credentials (service account keys)
- Security: Short-lived tokens with audit trail
- Simplicity: Kubernetes-native authentication pattern
- Customer control: Customer grants/revokes access via IAM

#### G5: Comprehensive Status Reporting

**Objective**: Provide detailed status information to HyperFleet API for decision-making.

**Success Metrics**:
- Three conditions reported: Applied, Available, Health
- Custom data includes GCP secret path and version
- Status updates within 5 seconds of job completion
- Clear failure reasons in error cases

**Rationale**:
- Sentinel needs status to decide next steps (trigger HyperShift adapter)
- Operators need visibility into provisioning progress
- Debugging requires detailed error information
- SLO tracking depends on accurate status

#### G6: Multi-Cloud Foundation (GCP MVP, Others Future)

**Objective**: Design adapter pattern that can extend to AWS, Azure in future.

**Success Metrics**:
- Abstract adapter framework supports pluggable cloud providers
- GCP-specific code isolated in provider package
- Configuration-driven (not code changes) for new clouds
- Consistent API contract across providers

**Rationale**:
- HyperFleet will support multiple cloud providers
- Avoid architectural debt that limits future expansion
- Reuse patterns across adapters (DNS, Infrastructure, etc.)
- Reduce implementation cost for future clouds

### Non-Goals

#### NG1: Pull Secret Generation or Validation

**What we're NOT doing**: The adapter does NOT generate, create, or validate the content of pull secrets.

**Rationale**:
- Pull secrets are provided by customers or AMS (Account Management Service)
- Adapter is solely responsible for storage and distribution
- Validation of credentials (e.g., testing registry login) is out of scope for MVP
- Future enhancement: Validation adapter could test credentials before storage

**Boundary**: Adapter assumes pull secret JSON is valid Dockercfg format and performs basic schema validation only (presence of `auths` key, valid JSON).

#### NG2: Pull Secret Rotation or Lifecycle Management

**What we're NOT doing**: Automatic rotation, expiration, or lifecycle policies for pull secrets.

**Rationale**:
- MVP focuses on initial provisioning
- Rotation requires coordination with customer's credential management
- Expiration policies vary by customer
- Manual rotation supported (trigger update event)

**Future Enhancement**: Post-MVP feature for automatic rotation based on policies.

#### NG3: Multi-Registry or Custom Registry Support (MVP)

**What we're NOT doing**: Support for custom/private registries beyond Red Hat registries (registry.redhat.io, quay.io).

**Rationale**:
- MVP scope limited to Red Hat registries
- Custom registries require additional validation and testing
- Different registries have different authentication mechanisms

**Future Enhancement**: M3 milestone includes support for customer-provided registries.

#### NG4: AWS or Azure Support (MVP)

**What we're NOT doing**: Support for AWS Secrets Manager or Azure Key Vault in MVP.

**Rationale**:
- GCP is the first cloud provider for HyperFleet MVP
- AWS and Azure require different SDK, authentication, and API patterns
- Architecture designed to support future expansion

**Future Enhancement**: M3 milestone includes AWS and Azure implementations.

#### NG5: Backup or Disaster Recovery

**What we're NOT doing**: Explicit backup/restore mechanisms for pull secrets.

**Rationale**:
- GCP Secret Manager provides built-in redundancy
- Secrets are re-creatable from source (HyperFleet API)
- Kubernetes secrets reconstructed from GCP on cluster recreation

**Dependency**: Relies on GCP Secret Manager's durability guarantees (automatic replication).

#### NG6: Secret Sharing Across Clusters

**What we're NOT doing**: Sharing a single pull secret across multiple clusters.

**Rationale**:
- Each cluster gets its own dedicated secret
- Isolation improves security (blast radius)
- Allows per-cluster rotation and revocation
- Simplifies lifecycle management

**Pattern**: One pull secret per cluster, named `hyperfleet-{cluster-id}-pull-secret`.

#### NG7: Pull Secret Migration from External Systems

**What we're NOT doing**: Migrating existing pull secrets from legacy systems.

**Rationale**:
- HyperFleet is a new platform (greenfield)
- Customers provide pull secrets via API or AMS integration
- No legacy state to migrate

**Note**: If customers have existing GCP secrets, they must be renamed or deleted to avoid conflicts.

---

## How

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    HyperFleet Platform                       │
│                  (Red Hat Management Cluster)                │
│                                                              │
│  ┌──────────┐      ┌────────────────┐      ┌─────────────┐ │
│  │ Sentinel │─────▶│ Message Broker │─────▶│   Adapter   │ │
│  └──────────┘      └────────────────┘      └──────┬──────┘ │
│       ▲                                            │         │
│       │                                            ▼         │
│  ┌────┴─────┐                            ┌─────────────┐   │
│  │   API    │◀───────────────────────────│     Job     │   │
│  └──────────┘      (POST status)         └──────┬──────┘   │
│                                                  │          │
└──────────────────────────────────────────────────┼──────────┘
                                                   │
                          ┌────────────────────────┼────────────────────┐
                          │  Workload Identity     │                    │
                          │  (Token Exchange)      │                    │
                          └────────────────────────┼────────────────────┘
                                                   ▼
                          ┌─────────────────────────────────────────────┐
                          │        Customer's GCP Project               │
                          │                                             │
                          │  ┌────────────────┐   ┌──────────────────┐ │
                          │  │ GCP SA         │   │ Secret Manager   │ │
                          │  │ (pullsecret-   │──▶│ hyperfleet-cls-* │ │
                          │  │  manager)      │   │                  │ │
                          │  └────────────────┘   └──────────────────┘ │
                          └─────────────────────────────────────────────┘
```

### Workflow Overview

#### Phase 1: Event Trigger (Sentinel → Adapter)

1. Sentinel polls HyperFleet API every 10 seconds
2. Detects cluster with dependencies complete (Validation, DNS, Placement)
3. Publishes `cluster.create` CloudEvent to message broker
4. Pull Secret Adapter consumes event from its subscription

#### Phase 2: Precondition Evaluation (Adapter)

5. Adapter fetches cluster details from API: `GET /clusters/{id}`
6. Evaluates preconditions using Expr expressions:
   - `spec.provider == "gcp"`
   - `spec.gcp.projectId != nil` (customer's project)
   - `spec.pullSecret.data != nil` (pull secret JSON exists)
   - `status.adapters[validation].available == "True"`
   - `status.adapters[dns].available == "True"`
   - `status.adapters[placement].available == "True"`
7. If all preconditions pass, proceed; otherwise skip event

#### Phase 3: Resource Creation (Adapter → Kubernetes)

8. Create temporary Kubernetes Secret containing pull secret data
   - Namespace: `hyperfleet-system`
   - Name: `cluster-{cluster-id}-pullsecret-data`
   - Used by Job as input

9. Create Kubernetes Job to execute provisioning
   - Name: `pullsecret-{cluster-id}-gen{generation}`
   - Service Account: `pullsecret-adapter-job` (with Workload Identity)
   - Environment: Cluster ID, GCP project ID, pull secret data, namespace

#### Phase 4: GCP Secret Manager Storage (Job)

10. Job authenticates via Workload Identity
    - Kubernetes SA token exchanged for GCP access token
    - Impersonates customer's GCP service account

11. Job checks if secret exists in GCP Secret Manager
    - `GetSecret(projects/{customer-project}/secrets/hyperfleet-{cluster-id}-pull-secret)`

12. If secret doesn't exist, create it:
    - `CreateSecret()` with labels: `managed-by=hyperfleet`, `cluster-id={id}`
    - Replication: Automatic (GCP-managed)

13. Add secret version with pull secret data:
    - `AddSecretVersion(payload: pull-secret-json)`
    - GCP returns version number (e.g., `1`, `2`, etc.)

14. Verify secret accessibility:
    - `AccessSecretVersion(latest)` to confirm readability

#### Phase 5: Kubernetes Secret Provisioning (Job)

15. Retrieve pull secret data from GCP Secret Manager

16. Determine target namespace from placement adapter:
    - Read `MANAGEMENT_NAMESPACE` environment variable
    - Example: `clusters-{cluster-id}` or `{region}-clusters`

17. Create or update Kubernetes Secret:
    - Type: `kubernetes.io/dockerconfigjson`
    - Name: `{cluster-id}-pull-secret`
    - Data: `.dockerconfigjson` (base64-encoded pull secret JSON)

18. Apply labels and annotations:
    - Labels: `managed-by=hyperfleet`, `cluster-id={id}`
    - Annotations: GCP secret path, creation timestamp

#### Phase 6: Status Reporting (Adapter → API)

19. Adapter monitors Job status via Kubernetes API

20. When Job completes successfully:
    - Extract conditions from Job status
    - Build status payload with three conditions:
      - **Applied**: Resources created successfully
      - **Available**: Secrets accessible and ready
      - **Health**: No failures detected

21. POST status to HyperFleet API:
    - `POST /clusters/{id}/statuses`
    - Body: `{adapter: "pullsecret", conditions: {...}, data: {...}}`

22. API saves status and updates `lastTransitionTime`

23. On next poll, Sentinel detects pull secret available
    - Triggers next adapter: HyperShift Adapter

### Key Design Decisions

#### Decision 1: Workload Identity vs. Service Account Keys

**Choice**: Use Workload Identity for GCP authentication

**Alternatives Considered**:
- Service account JSON keys stored in Kubernetes Secret
- Application Default Credentials with keys

**Rationale**:
- ✅ No long-lived credentials to manage/rotate
- ✅ Automatic token refresh
- ✅ Audit trail in GCP Cloud Audit Logs
- ✅ Customer grants/revokes access via IAM
- ✅ Industry best practice

**Trade-offs**:
- Requires customer to configure Workload Identity binding
- Slightly more complex initial setup
- Worth it for security benefits

#### Decision 2: Job Pattern vs. Adapter Direct Execution

**Choice**: Use Kubernetes Job pattern for execution

**Alternatives Considered**:
- Adapter directly calls GCP and K8s APIs
- Long-running daemon in adapter pod

**Rationale**:
- ✅ Isolation: Job failure doesn't crash adapter
- ✅ Resource limits: CPU/memory per job
- ✅ Retry: Kubernetes native retry mechanism
- ✅ Observability: Pod logs, metrics per cluster
- ✅ Cleanup: TTL deletes completed jobs

**Trade-offs**:
- Additional Kubernetes resource overhead
- Slight latency (pod scheduling)
- Worth it for reliability

#### Decision 3: Store in Customer's Project vs. Red Hat's Project

**Choice**: Store pull secrets in customer's GCP project

**Alternatives Considered**:
- Centralized secret storage in Red Hat project
- Shared secret across customers

**Rationale**:
- ✅ Data sovereignty: Customer owns their data
- ✅ Access control: Customer controls IAM
- ✅ Compliance: Meets regulatory requirements
- ✅ Auditability: Customer's audit logs
- ✅ Isolation: Customer breach doesn't affect others

**Trade-offs**:
- Requires Workload Identity setup per customer
- Cannot share secrets across customers
- Worth it for security and compliance

#### Decision 4: Kubernetes Secret Type

**Choice**: Use `kubernetes.io/dockerconfigjson` type

**Alternatives Considered**:
- Generic `Opaque` secret
- Custom type

**Rationale**:
- ✅ HyperShift expects this type
- ✅ Standard Kubernetes pattern
- ✅ Validation by Kubernetes
- ✅ Compatible with ImagePullSecrets

#### Decision 5: Secret Naming Convention

**Choice**: Auto-derive from cluster ID: `hyperfleet-{cluster-id}-pull-secret`

**Alternatives Considered**:
- User-provided secret name in cluster spec
- UUID-based naming

**Rationale**:
- ✅ Predictable and consistent
- ✅ Easy discovery by cluster ID
- ✅ Prevents conflicts (cluster ID is unique)
- ✅ Simplifies user experience (no naming required)

**Flexibility**: Allow optional override via `spec.pullSecret.secretName` for edge cases.

### Technology Choices

#### Programming Language: Go

**Reasons**:
- Native Kubernetes and GCP SDK support
- High performance, low resource usage
- Team expertise
- Standard for cloud-native projects

#### GCP SDK: `cloud.google.com/go/secretmanager`

**Reasons**:
- Official Google SDK
- Well-documented, actively maintained
- Type-safe API
- Automatic retry and error handling

#### Authentication: Workload Identity

**Reasons**:
- Eliminates service account keys
- Kubernetes-native pattern
- Recommended by Google for GKE
- Scales to multi-tenant environments

#### Logging: Structured JSON

**Reasons**:
- Machine-parseable for alerting
- Consistent with HyperFleet platform
- Easy correlation by cluster ID
- Supports log aggregation (Splunk, ELK)

#### Metrics: Prometheus

**Reasons**:
- Standard for Kubernetes
- Integrates with OpenShift monitoring
- Rich query language (PromQL)
- Supports SLO tracking

### Configuration

#### Adapter Configuration (YAML)

```yaml
spec:
  adapter:
    version: "1.0.0"

  # Event filter
  eventFilter:
    expression: |
      event.Type in ["cluster.create", "cluster.update"] &&
      event.Data.provider == "gcp"

  # Preconditions
  preconditions:
    - type: "api_call"
      method: "GET"
      endpoint: "/clusters/{clusterId}"
      when:
        expression: |
          cloudProvider == "gcp" &&
          gcpProjectId != nil &&
          pullSecretData != nil &&
          validationStatus == "True" &&
          dnsStatus == "True" &&
          placementStatus == "True"

  # Kubernetes resources to create
  resources:
    - kind: Secret  # Pull secret data for Job
    - kind: Job     # Execution

  # Status reporting
  post:
    conditions:
      - applied
      - available
      - health
```

#### Environment Variables (Job)

| Variable | Example | Source |
|----------|---------|--------|
| `CLUSTER_ID` | `cls-abc123` | Adapter |
| `GCP_PROJECT_ID` | `customer-prod-12345` | Cluster spec |
| `SECRET_NAME` | `hyperfleet-cls-abc123-pull-secret` | Auto-derived |
| `PULL_SECRET_DATA` | `{"auths": {...}}` | Cluster spec |
| `MANAGEMENT_NAMESPACE` | `clusters-cls-abc123` | Placement adapter |

### Security Measures

1. **No Secret Logging**: Pull secret data never logged
2. **TLS Everywhere**: All API calls use HTTPS
3. **RBAC**: Minimal permissions for service accounts
4. **Encryption at Rest**: GCP manages encryption keys
5. **Audit Logging**: All operations logged in Cloud Audit Logs
6. **Workload Identity**: No long-lived credentials
7. **Secret Rotation**: Supported via update events

### Observability

#### Metrics

```promql
# Job success rate
rate(pullsecret_job_total{result="success"}[5m])

# Average job duration
histogram_quantile(0.95, pullsecret_job_duration_seconds_bucket)

# GCP API errors
rate(pullsecret_gcp_api_calls_total{status_code=~"5.."}[5m])
```

#### Alerts

- Job failure rate > 10%
- Job duration > 5 minutes
- GCP API errors > 5% of requests
- Workload Identity failures

#### Logs

Structured JSON with correlation IDs:

```json
{
  "timestamp": "2025-11-13T10:30:45Z",
  "level": "info",
  "cluster_id": "cls-abc123",
  "gcp_project": "customer-prod-12345",
  "operation": "create-secret-version",
  "message": "Created secret version",
  "version": "1"
}
```

---

## Roll-out Plan

To minimize risks, rollout will be done in different milestones:

### Milestone 1 (M1): Pull Secret Service for MVP Scope

**Timeline**: Nov 2025 - Jan 2026

**Scope**:
- ✅ GCP Secret Manager integration
- ✅ Workload Identity authentication
- ✅ Kubernetes Secret provisioning
- ✅ Event-driven adapter framework
- ✅ Status reporting to HyperFleet API
- ✅ Basic metrics and logging

**Success Criteria**:
- Provision 100 test clusters successfully
- Average provisioning time < 30 seconds
- Zero security incidents
- All unit and integration tests pass

**Limitations**:
- GCP only (no AWS/Azure)
- Red Hat registries only (registry.redhat.io, quay.io)
- No automatic rotation
- Manual Workload Identity setup

**Deployment**:
- Staged rollout to dev → staging → production
- Canary deployment (10% → 50% → 100%)
- Feature flag controlled

### Milestone 2 (M2): Integration with AMS for Pull Secret Management

**Timeline**: Feb 2026 - Apr 2026

**Scope**:
- ✅ AMS (Account Management Service) integration
- ✅ Automatic pull secret retrieval from AMS
- ✅ Pull secret validation and testing
- ✅ Pull secret rotation support
- ✅ Enhanced error handling

**Success Criteria**:
- AMS integration with 99.9% uptime
- Automatic pull secret provisioning for all new clusters
- Zero manual pull secret operations
- Pull secret rotation working in staging

**Enhancements**:
- Remove dependency on user-provided pull secrets
- Centralized credential management via AMS
- Automated testing of registry credentials
- Better error messages for credential issues

**Dependencies**:
- AMS API availability
- AMS support for HyperFleet clusters

### Milestone 3 (M3): Multi-Cloud and Registry Support

**Timeline**: May 2026 - Jul 2026

**Scope**:
- ✅ AWS Secrets Manager support
- ✅ Azure Key Vault support
- ✅ Custom/private registry support
- ✅ Customer-managed encryption keys (CMEK)
- ✅ Advanced rotation policies

**Success Criteria**:
- All three clouds supported (GCP, AWS, Azure)
- Custom registries work for 10 pilot customers
- CMEK support verified in production
- Rotation policies configurable per customer

**Enhancements**:
- Provider abstraction (pluggable backends)
- Registry validation framework
- Customer-configurable policies
- Multi-registry support per cluster

**Challenges**:
- AWS and Azure have different APIs and authentication
- Custom registries have varying auth mechanisms
- CMEK requires customer key management

---

## Risks

### Risk 1: Workload Identity Setup Complexity

**Risk Level**: 🟡 Medium

**Description**: Customers must manually configure Workload Identity binding between Red Hat's Kubernetes service account and their GCP service account. This is a multi-step process involving IAM policies.

**Impact**:
- Setup failures delay cluster provisioning
- Support burden on operations team
- Poor customer experience

**Likelihood**: High (new customers unfamiliar with Workload Identity)

**Mitigation**:
1. **Documentation**: Step-by-step guide with screenshots
2. **Automation**: Provide Terraform/gcloud scripts
3. **Validation**: Pre-flight checks to verify setup
4. **Error Messages**: Clear instructions when binding fails
5. **Support**: Dedicated onboarding assistance for first 10 customers

**Monitoring**:
- Track Workload Identity failures in metrics
- Alert on repeated authentication errors
- Dashboard showing setup completion rate

### Risk 2: GCP API Rate Limiting

**Risk Level**: 🟡 Medium

**Description**: GCP Secret Manager has API quotas (600 writes/min, 600 reads/min per project). Bulk cluster provisioning could hit limits.

**Impact**:
- Provisioning delays during scale-up
- Failed jobs requiring retry
- Customer quota exhaustion

**Likelihood**: Medium (likely during large batch provisioning)

**Mitigation**:
1. **Batching**: Limit concurrent jobs per customer project
2. **Retry Logic**: Exponential backoff on `ResourceExhausted` errors
3. **Quota Monitoring**: Track customer quota usage
4. **Pre-scaling**: Request quota increases for large customers
5. **Documentation**: Inform customers of quota requirements

**Quota Defaults**:
- Write: 600 per minute per project
- Read: 600 per minute per project
- Access: 90,000 per minute per project (high)

**Monitoring**:
```promql
rate(pullsecret_gcp_api_calls_total{status_code="429"}[5m])
```

### Risk 3: Pull Secret Data Exposure

**Risk Level**: 🔴 High

**Description**: Pull secrets are highly sensitive credentials. Exposure in logs, metrics, or error messages would be a critical security incident.

**Impact**:
- Security breach
- Unauthorized registry access
- Compliance violations
- Customer trust loss

**Likelihood**: Low (with proper engineering) but high severity

**Mitigation**:
1. **Code Review**: Mandatory review for all secret-handling code
2. **Static Analysis**: Linters to detect secret logging
3. **Testing**: Automated tests verify no secret leakage
4. **Sanitization**: Redact secrets in error messages
5. **Audit**: Regular security audits of codebase
6. **Training**: Team training on secure coding practices

**Prevention**:
```go
// Never do this
log.Printf("Pull secret: %s", pullSecretData)

// Always do this
log.Printf("Processing pull secret for cluster %s", clusterID)
```

**Monitoring**:
- Log scanning for base64-encoded credentials
- Alerts on suspicious log patterns
- Security team reviews

### Risk 4: Secret Naming Conflicts

**Risk Level**: 🟢 Low

**Description**: Customers might have existing GCP secrets with the same name as HyperFleet would create (`hyperfleet-{cluster-id}-pull-secret`).

**Impact**:
- Job failure on secret creation
- Confusion about secret ownership
- Potential data loss if HyperFleet overwrites

**Likelihood**: Low (naming prefix reduces collision)

**Mitigation**:
1. **Pre-check**: Job checks for existing non-HyperFleet secrets
2. **Labels**: Verify `managed-by=hyperfleet` label before operations
3. **Error Message**: Clear error if conflict detected
4. **Documentation**: Document naming convention
5. **Override**: Allow customer to specify custom name if needed

**Handling**:
```go
if existingSecret.Labels["managed-by"] != "hyperfleet" {
    return fmt.Errorf("secret exists but not managed by HyperFleet")
}
```

### Risk 5: Kubernetes Secret Deletion by HyperShift

**Risk Level**: 🟡 Medium

**Description**: HyperShift or operators might accidentally delete the Kubernetes Secret in the management cluster.

**Impact**:
- Control plane cannot pull images
- Cluster provisioning stalls
- Requires manual intervention

**Likelihood**: Low (with proper RBAC) but possible

**Mitigation**:
1. **RBAC**: Restrict delete permissions on secrets
2. **Finalizers**: Add finalizer to prevent deletion (future)
3. **Drift Detection**: Sentinel detects missing secrets (future)
4. **Auto-Recreation**: Re-trigger adapter if secret missing
5. **Alerts**: Alert on secret deletion events

**Monitoring**:
```promql
kube_secret_deleted{namespace=~"clusters-.*", name=~".*-pull-secret"}
```

### Risk 6: Adapter Deployment Failures

**Risk Level**: 🟡 Medium

**Description**: Adapter service crashes, restarts, or becomes unavailable during critical provisioning.

**Impact**:
- Events not processed
- Jobs not created
- Clusters stuck in provisioning

**Likelihood**: Medium (any service can fail)

**Mitigation**:
1. **High Availability**: Run 2+ adapter replicas
2. **Pod Disruption Budget**: Prevent simultaneous restarts
3. **Health Checks**: Liveness and readiness probes
4. **Message Broker**: Events persist in queue (not lost)
5. **Retry**: Sentinel re-publishes events on next poll

**HA Configuration**:
```yaml
replicas: 2
podDisruptionBudget:
  minAvailable: 1
```

### Risk 7: Cross-Project IAM Complexity

**Risk Level**: 🟡 Medium

**Description**: Managing IAM permissions across customer projects is complex. Customers might misconfigure permissions.

**Impact**:
- Authentication failures
- Provisioning delays
- Increased support burden

**Likelihood**: Medium (IAM is complex)

**Mitigation**:
1. **Terraform Module**: Provide pre-built IAM configuration
2. **Pre-flight Validation**: Test permissions before provisioning
3. **Clear Errors**: Show exact missing permission in error message
4. **Documentation**: Detailed IAM setup guide
5. **Support Runbook**: Operations team runbook for common issues

**Required Permissions**:
```
secretmanager.secrets.create
secretmanager.secrets.get
secretmanager.versions.add
secretmanager.versions.access
```

**Validation**:
```bash
# Test script for customers
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:pullsecret-manager@*.iam.gserviceaccount.com"
```

---

## References

1. **HyperFleet Architecture**
   - https://github.com/openshift-hyperfleet/architecture
   - [Pull Secret Workflow Implementation](./pullsecret-workflow-implementation.md)
   - [GCP Secret Manager SDK Methods](./gcp-secret-manager-sdk-methods.md)

2. **GCP Documentation**
   - [Secret Manager Overview](https://cloud.google.com/secret-manager/docs)
   - [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
   - [IAM Best Practices](https://cloud.google.com/iam/docs/best-practices)

3. **HyperShift**
   - [HyperShift Documentation](https://hypershift-docs.netlify.app/)
   - [HostedCluster API](https://hypershift-docs.netlify.app/reference/api/)

4. **Internal References**
   - [RACI Matrix for Pull Secret Service](https://docs.google.com/spreadsheets/d/...)
   - [Tollbooth v2.0 - Use cases](https://docs.google.com/document/d/...)
   - [Bootstrap HyperFleet](https://github.com/openshift-online/bootstrap-hyperfleet/tree/main)

5. **JIRA**
   - [HYPERFLEET-162](https://issues.redhat.com/browse/HYPERFLEET-162) - Pull Secret Adapter Epic

---

## Acceptance Criteria

### AC1: GCP Secret Manager Integration

**Criteria**:
- [ ] Pull secrets successfully stored in customer's GCP Secret Manager
- [ ] Secrets created with correct labels: `managed-by=hyperfleet`, `cluster-id={id}`
- [ ] Secret naming follows convention: `hyperfleet-{cluster-id}-pull-secret`
- [ ] Secret versions increment correctly on updates
- [ ] Automatic replication policy applied

**Validation**:
```bash
# Verify secret exists in customer project
gcloud secrets describe hyperfleet-cls-123-pull-secret \
  --project=customer-prod-12345

# Verify labels
gcloud secrets describe hyperfleet-cls-123-pull-secret \
  --project=customer-prod-12345 \
  --format="value(labels.managed-by)"
# Expected: hyperfleet
```

### AC2: Kubernetes Secret Provisioning

**Criteria**:
- [ ] Kubernetes Secret created in correct namespace (from placement adapter)
- [ ] Secret type is `kubernetes.io/dockerconfigjson`
- [ ] Secret data contains valid Dockercfg JSON
- [ ] Secret has proper labels and annotations
- [ ] HyperShift can reference and use the secret

**Validation**:
```bash
# Verify K8s secret exists
kubectl get secret cls-123-pull-secret \
  -n clusters-cls-123 \
  -o yaml

# Verify type
kubectl get secret cls-123-pull-secret \
  -n clusters-cls-123 \
  -o jsonpath='{.type}'
# Expected: kubernetes.io/dockerconfigjson
```

### AC3: Workload Identity Authentication

**Criteria**:
- [ ] Job successfully authenticates to customer's GCP project
- [ ] No service account keys stored anywhere
- [ ] Token exchange happens transparently
- [ ] Authentication failures have clear error messages
- [ ] Cloud Audit Logs show authentication events

**Validation**:
```bash
# Check job logs for successful authentication
kubectl logs -n hyperfleet-system pullsecret-cls-123-gen1

# Verify in GCP Cloud Audit Logs
gcloud logging read \
  "protoPayload.authenticationInfo.principalEmail:pullsecret-manager@" \
  --project=customer-prod-12345 \
  --limit=10
```

### AC4: Event-Driven Workflow

**Criteria**:
- [ ] Adapter consumes events from message broker
- [ ] Preconditions evaluated correctly using Expr
- [ ] Jobs created only when all preconditions pass
- [ ] Events with missing data are skipped (not failed)
- [ ] Status posted to API after job completion

**Validation**:
```bash
# Simulate event and verify processing
# (Integration test)
curl -X POST http://message-broker/publish \
  -d '{"type": "cluster.create", "data": {"clusterId": "cls-test"}}'

# Verify job created
kubectl get job -n hyperfleet-system | grep pullsecret-cls-test

# Verify status posted
curl http://hyperfleet-api/clusters/cls-test/statuses
```

### AC5: Status Reporting

**Criteria**:
- [ ] Three conditions reported: Applied, Available, Health
- [ ] Conditions have status, reason, and message
- [ ] Custom data includes GCP secret path and version
- [ ] Status updates within 5 seconds of job completion
- [ ] Failed jobs report error details

**Validation**:
```json
// Expected status structure
{
  "adapterName": "pullsecret",
  "conditions": {
    "applied": {
      "status": "True",
      "reason": "SecretCreated",
      "message": "Pull secret successfully created"
    },
    "available": {
      "status": "True",
      "reason": "SecretAvailable",
      "message": "Secret accessible in GCP Secret Manager"
    },
    "health": {
      "status": "True",
      "reason": "Healthy",
      "message": "Adapter functioning normally"
    }
  },
  "data": {
    "secretName": "hyperfleet-cls-123-pull-secret",
    "secretPath": "projects/customer-proj/secrets/.../versions/latest",
    "gcpProject": "customer-prod-12345"
  }
}
```

### AC6: Error Handling

**Criteria**:
- [ ] Transient errors (network, rate limit) retried with backoff
- [ ] Permanent errors (invalid data) fail immediately
- [ ] Error messages do not contain pull secret data
- [ ] Failed jobs have non-zero exit code
- [ ] Adapter continues processing after individual failures

**Validation**:
```bash
# Simulate quota exceeded error
# (Integration test with mocked GCP API)

# Verify retry with backoff in logs
kubectl logs -n hyperfleet-system pullsecret-cls-123-gen1 | grep "Retry"

# Verify no secret data in logs
kubectl logs -n hyperfleet-system pullsecret-cls-123-gen1 | grep -E "auth|password|token"
# Expected: No matches
```

### AC7: Observability

**Criteria**:
- [ ] Prometheus metrics exposed on `/metrics` endpoint
- [ ] Metrics include job duration, success rate, API calls
- [ ] Structured JSON logs with cluster ID correlation
- [ ] Logs do not contain sensitive data
- [ ] Dashboards available in Grafana

**Validation**:
```bash
# Verify metrics endpoint
curl http://pullsecret-adapter:8080/metrics | grep pullsecret

# Expected metrics:
# pullsecret_job_duration_seconds
# pullsecret_job_total{result="success"}
# pullsecret_gcp_api_calls_total

# Verify log structure
kubectl logs -n hyperfleet-system \
  -l app=pullsecret-adapter | jq .
```

### AC8: Security

**Criteria**:
- [ ] Pull secret data never logged
- [ ] All API calls use TLS
- [ ] Job runs as non-root user (UID 1000)
- [ ] No privilege escalation allowed
- [ ] Read-only root filesystem
- [ ] Service account has minimal RBAC permissions

**Validation**:
```bash
# Verify security context
kubectl get pod pullsecret-cls-123-gen1 \
  -n hyperfleet-system \
  -o jsonpath='{.spec.securityContext}'

# Expected:
# {
#   "runAsNonRoot": true,
#   "runAsUser": 1000,
#   "allowPrivilegeEscalation": false,
#   "readOnlyRootFilesystem": true
# }
```

### AC9: Performance

**Criteria**:
- [ ] Average job duration < 30 seconds (95th percentile)
- [ ] Adapter processes events within 2 seconds
- [ ] No more than 100 MB memory per job
- [ ] Adapter handles 100 concurrent jobs
- [ ] GCP API calls < 2 seconds (95th percentile)

**Validation**:
```promql
# Job duration
histogram_quantile(0.95, pullsecret_job_duration_seconds_bucket)
# Expected: < 30

# Memory usage
max(container_memory_usage_bytes{pod=~"pullsecret-.*"}) / 1024 / 1024
# Expected: < 100
```

### AC10: Documentation

**Criteria**:
- [ ] README with architecture overview
- [ ] Setup guide for Workload Identity
- [ ] Troubleshooting guide with common errors
- [ ] API documentation for status format
- [ ] Runbook for operations team

**Validation**:
- All documentation files present in repository
- Documentation reviewed and approved
- Links verified (no 404s)
- Code examples tested

---

**Document Owner**: Leonardo Dorneles
**Last Updated**: Nov 14, 2025
**Next Review**: Dec 2025 (post-M1 completion)
