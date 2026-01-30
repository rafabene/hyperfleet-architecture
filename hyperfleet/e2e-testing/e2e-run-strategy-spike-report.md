# Spike Report: HyperFleet E2E Test Automation Run Strategy

**JIRA Story:** HYPERFLEET-532  
**Status:** Draft  
**Focus:** Deployment lifecycle management, resource isolation, and parallel Test Run execution safety

---

## 1. Problem Statement

HyperFleet E2E testing validates system-level behavior across multiple cooperating components, including:

- HyperFleet API
- Sentinel
- Adapter framework (multiple adapter types)
- Messaging broker (Topics / Subscriptions)

As E2E coverage expands and test pipelines begin executing in parallel, the current approach lacks a clearly defined **E2E test run strategy** to govern:

- Deployment lifecycle ownership
- Resource isolation boundaries
- Race condition prevention in concurrent executions
- Reliable cleanup and observability

This results in:

- Flaky test failures caused by shared resources
- Unclear ownership of deployed components
- Orphaned Kubernetes and broker resources
- Limited scalability of parallel pipelines

This spike defines a **comprehensive E2E test automation run strategy**, focusing on how tests are **deployed, isolated, coordinated, and cleaned up**, rather than on individual test case logic.

---

## 2. Goals and Non-Goals

### 2.1 Goals

This spike aims to define a strategy that:

- Enables **safe parallel execution** of multiple Test Runs
- Ensures **strong resource isolation** between test runs
- Clearly defines **deployment lifecycle ownership**
- Prevents race conditions by design
- Supports **dynamic adapter deployment and removal** (hot-plugging)
- Improves **debuggability and maintainability**
- Establishes reusable patterns for future E2E expansion

---

### 2.2 Non-Goals

This spike explicitly does **not** cover:

- Individual test case implementation
- CI/CD pipeline configuration
- Performance or load testing considerations
- External environments not related to HyperFleet (such as cloud resources)

---

## 3. Core Design Principles

### 3.1 Test Run as the Primary Isolation Unit

All test infrastructure, configuration, and resources are scoped to a **single Test Run**.

A Test Run is the smallest unit of:

- Isolation
- Resource ownership

---

### 3.2 Explicit Lifecycle Ownership

Every component participating in E2E testing must have clearly defined ownership for:

- Creation
- Runtime management
- Teardown

Implicit or shared ownership is considered a design flaw.

---

### 3.3 Isolation Over Optimization

When trade-offs exist, this strategy prioritizes:

> Reliability, isolation, and debuggability over startup speed or resource reuse.

---

## 4. E2E Test Run Model

### 4.1 Test Run Definition

A **Test Run** represents one or more E2E test cases executed sequentially as a single unit.

Each Test Run has:

- A globally unique **Test Run ID**
- A well-defined lifecycle: `setup → execute → teardown`
- Exclusive ownership of all resources it creates

---

### 4.2 Test Run Identification

Each Test Run generates a unique identifier (Test Run ID) derived from:

- CI-provided environment variable (when available)
- Unix timestamp with high entropy
- Customized with random components

The Test Run ID is consistently applied to:

- Kubernetes Namespaces
- Resource names
- Broker Topics and Subscriptions
- Labels and annotations

Namespaces are additionally labeled to indicate execution context:

- Label `ci` distinguishes CI pipeline runs (`yes`) from local developer runs (`no`)
- Enables context-appropriate retention policies
- Does not affect test execution behavior

This ensures **traceability** and **collision avoidance**.

---

### 4.3 Test Run Lifecycle

Each Test Run follows a well-defined lifecycle:

```
Create Namespace
      ↓
Deploy Infrastructure
      ↓
Infrastructure Ready
      ↓
Execute Test Suites
      ↓
Cleanup
```

**Infrastructure Deployment** includes:
- Database (PostgreSQL, deployed with API)
- API and Sentinel
- Broker connectivity
- Custom Resource Definitions (CRDs)
- Fixture Adapter

**Infrastructure Ready** means:
- All infrastructure components are healthy
- Fixture Adapter is operational
- Test suites can execute independently
- No production adapters are deployed yet

**Test Suite Execution**:
- Suites execute sequentially
- Each suite may deploy/remove production adapters as needed
- Environment state persists across suites within the same Test Run

---

### 4.4 Fixture Adapter

The **Fixture Adapter** is a minimal test infrastructure component deployed as part of the Test Run.

**Purpose**:
- Enables core workflows (cluster/nodepool lifecycle) to complete independently
- Provides stable baseline for adapter-independent testing
- Acts as minimal event consumer for workflow completion

**Characteristics**:
- Deployed during Test Run setup
- Lifecycle owned by Test Framework
- Not used for business logic validation
- Remains active throughout the Test Run

---

## 5. Deployment Lifecycle Strategy

### 5.1 One Namespace per Test Run

Each Test Run is assigned a **dedicated Kubernetes Namespace**.

This Namespace serves as the hard isolation boundary for:

- API
- Sentinel
- Adapters
- Supporting services (databases, brokers, etc.)

**Rationale:**

- Eliminates cross-test interference
- Simplifies cleanup semantics
- Improves debugging clarity
- Avoids complex naming or locking schemes

---

### 5.2 Namespace Naming Convention

Namespace names follow a consistent pattern for operational clarity:

```
e2e-singlens-{TEST_RUN_ID}
```

**Components**:
- `e2e-`: Prefix indicating E2E test resources
- `singlens-`: Topology indicator (standard single-namespace deployment)
- `{TEST_RUN_ID}`: Unique test run identifier

**Rationale**:
- Deployment model immediately visible from namespace name
- Test Run ID enables correlation of resources across test runs
- Operational teams can identify E2E namespaces without inspecting labels

---

### 5.3 Cross-Namespace Topology (Advanced)

For tests requiring production-realistic deployment validation, an **optional cross-namespace topology** is supported:

```
e2e-crossns-{TEST_RUN_ID}-core
e2e-crossns-{TEST_RUN_ID}-adapters
```

**Structure**:
- `-core` namespace: API, Sentinel, Broker
- `-adapters` namespace: Adapter components
- Both share same `TEST_RUN_ID` for correlation

**Use Cases**:
- Validating cross-namespace communication (Service DNS, NetworkPolicy)
- Security boundary testing
- Production deployment model verification

**Trade-offs**:
- Increased setup complexity
- Requires additional RBAC configuration
- Suitable for integration and security validation tests only

Most E2E tests should use the standard single-namespace topology.

---

### 5.4 Component Lifecycle Ownership

| Component          | Lifecycle Owner  | Scope        | Notes |
|--------------------|------------------|--------------|-------|
| Namespace          | Test Framework   | Per Test Run | |
| API                | Test Framework   | Per Test Run | |
| Sentinel           | Test Framework   | Per Test Run | |
| Fixture Adapter    | Test Framework   | Per Test Run | Infrastructure component |
| Production Adapter | Test Suite       | Suite-scoped | Dynamically managed |
| Broker Resources   | Adapter/Sentinel | Per Test Run | |

**Rule:**
No component may create resources outside its Test Run Namespace without Test Run–level isolation.

---

### 5.5 Resource Labeling Strategy

#### 5.5.1 Required Labels

All E2E test namespaces must carry exactly three labels:

1. **`ci`**: Execution context (`yes` | `no`)
2. **`test-run-id`**: Test Run identifier
3. **`managed-by`**: Ownership marker (`e2e-test-framework`)

**Rationale**:
- `ci`: Enables context-appropriate retention policies
- `test-run-id`: Enables resource correlation and traceability
- `managed-by`: Standard Kubernetes ownership marker

---

## 6. Resource Isolation Strategy

### 6.1 Kubernetes Resource Isolation

Isolation is achieved via:

- Namespace-per-Test-Run
- Consistent `test-run-id` labeling
- Optional but recommended `ResourceQuota` and `LimitRange`

This prevents:

- Pod name collisions
- Service discovery conflicts
- Cross-test communication

---

### 6.2 Messaging and Broker Isolation

Messaging resources (Topics / Subscriptions) are isolated using the Test Run ID.

Common patterns include:

- Run-scoped Topics
- Run-scoped Subscriptions
- Adapter-owned Subscription lifecycles

This avoids:

- Cross-test event delivery
- Subscription reuse race conditions
- Message leakage between runs

---

## 7. Race Condition Prevention

Race conditions are prevented through **architectural isolation**, not runtime locking.

### 7.1 Unique Resource Identification

All externally visible resources include the Test Run ID in:

- Names
- Labels
- Broker identifiers

This guarantees uniqueness even under maximum concurrency.

---

### 7.2 No Shared Mutable State

The strategy explicitly avoids:

- Shared Namespaces
- Shared Topics or Subscriptions
- Shared databases
- Shared API instances

Shared mutable state is the primary source of E2E race conditions.

---

### 7.3 Parallel Test Run Execution Model

Parallel pipelines are safe because:

- Each Test Run executes within a sealed resource boundary
- No global locks are required
- Failures are contained within a single Namespace

---

## 8. Test Scenario Organization

### 8.1 Lifecycle Management Model

Test infrastructure is managed at the **Test Run level**, not per test case.

- Infrastructure is deployed once per Test Run
- All test suites share the same environment
- Test cases focus on validation, not deployment

This ensures:
- Stable environment for workflow validation
- Reduced setup overhead
- Clear separation between infrastructure and behavior testing

---

### 8.2 Test Suite Types

Test suites represent **validation focus**, not environment configurations.

#### 8.2.1 Core Suite

Validates cluster and nodepool workflows using only core components.

**Environment**:
- Core components (API, Sentinel, Broker)
- Fixture Adapter only (no production adapters)

**Validates**:
- Cluster lifecycle (create, ready, delete)
- NodePool lifecycle
- Event-driven workflow completion
- Core component behavior under baseline conditions

**Example flow**: Create cluster → Sentinel publishes event → Fixture Adapter consumes → Reports success → Cluster becomes Ready

---

#### 8.2.2 Adapter Execution Suite

Validates adapter runtime behavior and job execution.

**Environment**:
- Core components deployed
- Production adapters hot-plugged **at suite level** (beforeSuite/afterSuite)

**Validates**:
- Adapter job execution (e.g., Kubernetes namespace creation)
- Event handling correctness
- Error handling and retries
- Resource reconciliation

**Adapter Management**:
- Adapters deployed once in beforeSuite
- Shared across all test cases in the suite
- Removed in afterSuite
- Tests adapter runtime behavior, not deployment process

---

#### 8.2.3 Adapter Deployment Suite

Validates adapter installation, configuration, and removal correctness.

**Environment**:
- Core components deployed
- Production adapters hot-plugged **per test case**

**Validates**:
- Adapter deployment process
- Configuration correctness
- Subscription registration
- Adapter health and readiness
- Adapter removal and cleanup
- Resource cleanup completeness

**Adapter Management**:
- Each test case deploys and removes its own adapter instance
- Tests the complete deployment/teardown lifecycle
- Enables testing of various adapter configurations

---

### 8.3 Adapter Lifecycle Management

Production adapters are **dynamically managed** within a Test Run:

**Hot-plugging**:
- Adapters can be added or removed between suites or test cases
- Multiple adapters can be deployed in parallel
- Each adapter maintains independent subscriptions

**Ownership**:
- Test Suite owns adapter lifecycle within its scope
- Adapters are treated as test variables, not infrastructure constants

**Subscription Management**:
- Each adapter creates unique subscriptions
- Subscription IDs ensure isolation between adapter instances

**Independence**:
- Core Suite operates independently via Fixture Adapter
- Adapter failures do not impact infrastructure stability

---

### 8.4 Suite Execution Order

**Recommended Order**:

Within a Test Run, suites typically execute in this order:

1. **Core Suite** - Validates baseline functionality (must run first)
2. **Adapter Execution Suite** - Validates adapter runtime behavior
3. **Adapter Deployment Suite** - Validates adapter deployment process

**Rationale**:
- Core Suite must run first to validate infrastructure readiness
- Adapter Execution and Deployment suites have no dependency on each other
- Adapter Execution Suite runs before Deployment Suite to minimize environment pollution:
  - Execution Suite manages adapters at suite level (cleaner state isolation)
  - Deployment Suite creates/removes adapters per test case (higher churn)

**Flexibility**:
- Adapter Execution and Deployment suites can run in either order or in parallel (separate Test Runs)
- Any suite can run independently if infrastructure is ready
- Order recommendation optimizes for state cleanliness, not correctness

---

### 8.5 State Management and Suite Independence

**State Ownership Model**:

Test Run state is categorized by lifetime and ownership:

| State Type | Lifetime | Owner | Examples |
|------------|----------|-------|----------|
| Infrastructure State | Test Run | Test Framework | Namespace, API, Sentinel, Fixture Adapter |
| Adapter State | Suite or Test Case | Test Suite | Production adapter pods, subscriptions |
| Test Data | Test Case | Test Case | Clusters, NodePools, test-specific resources |

**Isolation Principles**:

1. **Infrastructure persists** - Core components remain active throughout the Test Run
2. **Adapters are ephemeral** - Created and removed by test suites as needed
3. **Test data is scoped** - Each test case manages its own test resources
4. **Unique naming prevents collision** - Resources use unique identifiers to avoid cross-test interference

**Suite Independence**:

- Suites can run independently if infrastructure is ready
- Suite failures do not block subsequent suites (collect all failures)
- Each suite validates its prerequisites at startup

**Cleanup Responsibility**:

- Test cases and suites clean their own state (adapters, test data)
- Infrastructure cleanup handled by Test Framework (see Section 9 for retention policy)

---

## 9. Resource Management and Cleanup

### 9.1 Cleanup Ownership Model

Cleanup is a shared responsibility between two actors:

1. **E2E Test Flow**: Responsible for setting retention policy and deleting passed tests
2. **Reconciler Job**: Responsible for enforcing TTL and handling edge cases

No single component owns all cleanup. This separation prevents single points of failure.

---

### 9.2 Retention Policy

#### 9.2.1 Default Retention (Safe Fallback)

All namespaces are annotated with a default retention policy at creation:

- **Default TTL**: 2 hours from creation
- **Purpose**: Safety net if E2E flow is interrupted or fails before updating retention
- Ensures orphaned namespaces are automatically cleaned up

#### 9.2.2 Test Result-Based Retention

E2E flow updates namespace retention annotations based on test outcome:

| Test Result | CI Context | Local Context | Retention |
|-------------|------------|---------------|-----------|
| **Passed** | Any | Any | 10 minutes |
| **Failed** | `ci=yes` | - | 24 hours |
| **Failed** | `ci=no` | `ci=no` | 6 hours |

**Rationale**:
- Passed tests have minimal debugging value → short retention conserves quota
  - 10-minute window prevents race conditions between E2E flow and reconciler deletion
- Failed tests need retention for post-mortem
  - CI (24h): Global team across time zones
  - Local (6h): Developer actively investigating
- Default 2h retention: Covers interrupted E2E flows

#### 9.2.3 Retention Override

Environment-based configuration allows overriding default retention policy.

**Use Cases**:
- Extended debugging sessions
- Demonstration environments
- Manual investigation

Override values are stored in namespace annotations for reconciler consumption.

---

### 9.3 Cleanup Reconciliation

#### 9.3.1 Reconciler Responsibilities

A scheduled reconciler job enforces TTL-based cleanup:

- Runs periodically (frequency configurable, typically 30 minutes)
- Scopes to namespaces labeled as E2E test framework managed
- Deletes namespaces based on retention annotation expiry

**Simplicity Principle**: Reconciler does not distinguish between:
- Normal vs orphaned namespaces
- CI vs local runs
- Single-namespace vs cross-namespace

All policy decisions are encoded in namespace annotations. Reconciler is stateless.

#### 9.3.2 Cross-Namespace Correlation

For cross-namespace deployments, reconciler must correlate related namespaces:
- Identifies topology from namespace naming convention
- Finds all namespaces sharing the same Test Run ID
- Deletes correlated namespaces together

**Atomicity**: Deletion may be eventual (one namespace deleted, others follow in next reconciliation cycle). This is acceptable given low-frequency reconciliation.

---

### 9.4 Orphaned Resource Handling

**Definition**: Orphaned resources occur when E2E flow is interrupted before setting final retention.

**Handling**:
- No special orphan detection needed
- Default 2-hour retention set at creation covers this case
- Reconciler treats orphans identically to any expired namespace

**Monitoring**: High orphan rate (inferred from default retention deletions) indicates E2E flow reliability issues.

---

## 10. Testing Infrastructure Considerations

### 10.1 Image Build and Distribution

**Image Architecture**:

Test infrastructure uses two container images with distinct responsibilities:

1. **Cloud Platform Tools** - Target cluster authentication
   - Contains cloud provider CLIs (gcloud, aws, etc.)
   - Runs as init container to generate cluster credentials
   - Low change frequency (rebuilt only when cloud tooling updates)

2. **E2E Test Framework** - Infrastructure deployment and test execution
   - Contains helm CLI, test code, and deployment charts
   - Manages entire Test Run lifecycle
   - High change frequency (rebuilt on test code or chart changes)

**Rationale**:
- Adapter hot-plugging requires deployment tooling in test execution context
- Infrastructure deployment is orchestrated by Test Framework (Section 5.4)
- Separation by change frequency optimizes CI/CD build efficiency

---

## 11. Observability and Debugging

Debuggability is enabled by:

- One Namespace per Test Run
- Consistent labeling and naming conventions
- Clear lifecycle boundaries
- Namespace retention on failure
- Component version reporting

**Version Transparency**:

Test framework outputs component versions at Test Run start:
- Core components (API, Sentinel, Broker)
- Fixture Adapter
- Production adapters deployed during test execution

This enables correlation between test results and component versions for failure investigation.

Engineers can:

- Inspect all failed-test resources in a single Namespace
- Correlate logs, events, and message flows
- Reproduce failures with exact component versions
- Identify version-specific issues

---

## 12. Open Questions and Follow-Ups

The following topic is intentionally deferred to implementation phase:

- What is the minimal functional specification for Fixture Adapter?

---

## 13. Action Items and Next Steps

**Prerequisites**: This test strategy assumes HyperFleet system supports runtime adapter hot-plugging (dynamic adapter deployment without API/Sentinel restart). If this capability does not exist, it should be implemented as part of HyperFleet core development (separate from E2E framework work).

### 13.1 Core Infrastructure

**HYPERFLEET-XXX: Container Image Architecture**
- [ ] Build Cloud Platform Tools image (gcloud, aws cli, kubeconfig generation)
- [ ] Build E2E Test Framework image (helm cli, test code, deployment charts)
- [ ] Set up image build pipeline

**HYPERFLEET-XXX: Test Run Lifecycle**
- [ ] Implement Test Run ID generation
- [ ] Implement namespace creation with isolation labels (test-run-id, ci, managed-by)
- [ ] Implement infrastructure deployment via helm (API, Sentinel, Broker)
- [ ] Add infrastructure readiness checks
- [ ] Implement cleanup: helm uninstall + namespace deletion

**HYPERFLEET-XXX: Fixture Adapter**
- [ ] Design minimal functional specification for Fixture Adapter
- [ ] Implement Fixture Adapter with event consumption capability
- [ ] Add Fixture Adapter to infrastructure helm chart
- [ ] Write Fixture Adapter unit tests

**HYPERFLEET-XXX: Component Version Reporting**
- [ ] Implement version output at Test Run start
- [ ] Output core component versions (API, Sentinel, Broker, Fixture Adapter)
- [ ] Log production adapter versions during test execution

### 13.2 Test Suite Implementation

**HYPERFLEET-XXX: Core Suite**
- [ ] Implement Core Suite test cases (cluster/nodepool lifecycle)
- [ ] Verify Core Suite operates with Fixture Adapter only
- [ ] Add infrastructure health validation

**HYPERFLEET-XXX: Adapter Execution Suite**
- [ ] Implement suite-level adapter deployment (beforeSuite/afterSuite)
- [ ] Write adapter job execution tests
- [ ] Add event handling and error handling validation

**HYPERFLEET-XXX: Adapter Deployment Suite**
- [ ] Implement per-test-case adapter deployment helpers (helm install/uninstall)
- [ ] Create adapter configuration testdata directory (helm values for adapter deployment)
- [ ] Write adapter deployment and removal validation tests
- [ ] Add cleanup completeness verification

### 13.3 Documentation

**HYPERFLEET-XXX: E2E Test Run Strategy Guide**
- [ ] Document Test Run lifecycle for developers
- [ ] Write suite type selection guide (Core/Execution/Deployment)
- [ ] Create adapter hot-plugging examples
- [ ] Document basic cleanup and troubleshooting

### 13.4 Future Enhancements

The following enhancements are deferred to post-MVP:

**HYPERFLEET-XXX: Cross-Namespace Topology**
- [ ] Implement cross-namespace deployment model (e2e-crossns-{ID}-core, e2e-crossns-{ID}-adapters)
- [ ] Add cross-namespace DNS and NetworkPolicy configuration
- [ ] Update cleanup logic for cross-namespace correlation
- [ ] Write cross-namespace communication validation tests
- [ ] Document production deployment model verification use cases

**HYPERFLEET-XXX: Retention Policy**
- [ ] Implement namespace retention annotation logic
- [ ] Add test result-based retention updates (passed: 10min, failed: 24h/6h)
- [ ] Configure default 2-hour TTL for orphaned namespaces
- [ ] Write retention policy unit tests

**HYPERFLEET-XXX: Cleanup Reconciler Job**
- [ ] Implement TTL-based namespace reconciler
- [ ] Add orphaned resource detection and cleanup
- [ ] Add cross-namespace correlation for multi-namespace topologies
- [ ] Configure reconciler schedule (30-minute default)
- [ ] Add reconciler monitoring and alerts

---

**Document Status**: Draft for Review
**Next Steps**: Team review and approval, then create implementation tickets
