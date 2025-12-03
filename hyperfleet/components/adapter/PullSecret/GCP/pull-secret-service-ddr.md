# Pull Secret Service for HyperFleet Architecture

## Executive Summary

The Pull Secret Adapter is responsible for securely storing and managing image registry pull secrets in GCP Secret Manager for HyperShift-managed OpenShift clusters. These secrets enable cluster nodes to pull container images from authenticated registries (e.g., Red Hat registries, Quay.io).

The service operates as an event-driven adapter within the HyperFleet architecture, consuming CloudEvents from Sentinel and orchestrating two critical workflows:
1. Storing pull secrets in the customer's GCP Secret Manager for worker node access
2. Provisioning Kubernetes secrets in the management cluster for HyperShift control plane access

---

## What

### Overview

The Pull Secret Service is an event-driven adapter that manages the complete lifecycle of image registry pull secrets for HyperShift-managed OpenShift clusters provisioned on Google Cloud Platform (GCP).

### Roll-out Plan

To minimize the risks related to this, rollout will be done in different milestones:

- **M1:** Pull Secret Service for MVP scope
- **M2:** Pull Secret Service to extract out quay functionality from AMS
- **M3:** Pull Secret Service to support for other clouds and registries

### Responsibilities

#### M1. GCP Secret Manager Storage

- Implement a message broker to publish and subscribe to pull secret related messages
- Create internal API/Services/Jobs to maintain customer's pull secrets
- Store pull secret credentials in RedHat GCP Secret Manager
- Add test coverage to validate the pull secret adapter functionalities

> **Note:** M1 is purely a CS task, as it involves storing pull secret data in a vault (GCP Secret Manager)

---

## HyperFleet Architecture - High Level Design

### Core Components

| Component | What | Source |
|-----------|------|--------|
| **HyperFleet API** | Simple REST API providing CRUD operations for HyperFleet resources (clusters, node pools, etc.) and their statuses | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#1-hyperfleet-api) |
| **Database (PostgreSQL)** | Persistent storage for cluster resources and adapter status updates | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#2-database-postgresql) |
| **Sentinel** | Service that continuously polls HyperFleet API, decides when resources need reconciliation, creates events, and publishes them to the message broker | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#3-sentinel) |
| **Message Broker** | Message broker implementing fan-out pattern to distribute reconciliation events to multiple adapters | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#4-message-broker) |
| **Adapter Deployments** | Event-driven services that consume reconciliation events, evaluate preconditions, create Kubernetes Jobs, and report status back to HyperFleet API | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#5-adapter-deployments) |
| **Kubernetes Resources** | Kubernetes resources (like pipelines/jobs) created by adapters to execute provisioning tasks and manage cluster lifecycle | [Link](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#6-kubernetes-resources) |

![HyperFleet Architecture - High Level Overview](./images/image3.png)


**Source:** https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#high-level-overview

### Adapter Types (MVP)

**Scope:** ~5 adapters for GCP cluster provisioning

1. **Validation Adapter** - Check GCP prerequisites
2. **DNS Adapter** - Create Cloud DNS records
3. **Placement Adapter** - Select region and management cluster
4. **Pull Secret Adapter** - Store credentials in Secret Manager
5. **HyperShift Adapter** - Create HostedCluster CR

**Source:** https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/mvp/mvp-scope.md

### Adapter Workflow

Using cluster creation as an example:

```
1. Consume event from broker subscription
2. Fetch cluster details from API: GET /clusters/{id}
3. Evaluate preconditions:
   - Check adapter-specific requirements
   - Check dependencies (e.g., DNS requires Validation complete)
4. IF preconditions met:
     - Create Kubernetes Job with cluster context
     - Job executes adapter logic (e.g., call cloud provider APIs)
     - Monitor job completion
5. Report status (adapter always POSTs - API handles upsert internally):
   POST /clusters/{id}/statuses

   Payload example:
   {
     "adapter": "dns",                     // Identifies which adapter is reporting
     "observedGeneration": 1,
     "conditions": [
       {
         "type": "Available",
         "status": "True",
         "reason": "AllRecordsCreated",
         "message": "All DNS records created and verified",
         "lastTransitionTime": "2025-10-21T14:35:00Z"
       },
       {
         "type": "Applied",
         "status": "True",
         "reason": "JobLaunched",
         "message": "DNS Job created successfully",
         "lastTransitionTime": "2025-10-21T14:33:00Z"
       },
       {
         "type": "Health",
         "status": "True",
         "reason": "NoErrors",
         "message": "DNS adapter executed without errors",
         "lastTransitionTime": "2025-10-21T14:35:00Z"
       }
     ],
     "data": {
       "recordsCreated": ["api.cluster.example.com", "*.apps.cluster.example.com"]
     },
     "lastUpdated": "2025-10-21T14:35:00Z"    // When adapter checked (now())
   }

   API response: 200 OK (whether first report or update)
6. Acknowledge message to broker
```

**Source:** https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#5-adapter-deployments

### Configuration (via AdapterConfig)

```yaml
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: AdapterConfig
metadata:
  name: validation-adapter
  namespace: hyperfleet-system
spec:
  adapterType: validation

  # Precondition criteria for when adapter should run
  criteria:
    preconditions:
      - expression: "cluster.status.phase != 'Ready'"
    dependencies: []

  # HyperFleet API configuration
  hyperfleetAPI:
    url: http://hyperfleet-api:8080
    timeout: 10s

  # Message broker configuration
  broker:
    type: gcp-pubsub
    subscription: validation-adapter-sub

  # Job template configuration
  jobTemplate:
    image: quay.io/hyperfleet/validation-job:v1.0.0
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

**Source:** https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/architecture/architecture-summary.md#5-adapter-deployments

---

## Pull Secret Architecture - Key Components

| Component | Type | Purpose |
|-----------|------|---------|
| **Pull Secret Adapter** | Deployment | Consumes events, orchestrates jobs, reports status |
| **Pull Secret Job** | Job | Executes GCP API calls or uses the GCP SDK both related to GCP Secret Manager and K8s secret operations |
| **GCP Secret Manager** | External Service | Stores pull secret data in customer's project |
| **Kubernetes Secret** | Resource | Provides pull secret to HyperShift |

### Integration Points

- **Upstream:** Sentinel Service (event producer)
- **Downstream:** HyperFleet API (status consumer)
- **External:** GCP Secret Manager API (GCP Project ID from a Management Cluster)
- **Internal:** Kubernetes API (management cluster)
- **Dependencies:** Validation, DNS, Placement adapters (must complete first)

### High-Level Architecture

![Pull Secret Architecture - High Level](./images/image2.png)

### Assumptions

- Hardcoded Pull Secret to unlock the MVP (see notes: [Hyperfleet MVP Kickoff - 2025/11/07 20:53 CST](https://docs.google.com/document/d/1XKLt1M4kQxMIh4eicdM5Tk092MU9VpUBifXMVnml8xQ))
- RH Project ID from Regional Cluster will be used to enable the Secret Manager API
  - https://docs.cloud.google.com/secret-manager/docs/configuring-secret-manager#enable-the-secret-manager-api
  - For the staging environment, the following GCP project will be used:
    - https://console.cloud.google.com/welcome?project=sda-ccs-3

![Architecture with Assumptions](./images/image5.png)

### MVP Scope

MVP Scope - primarily focused on the Job implementation (see notes: [HyperFleet: Pull Secret Service - Standup - 2025/11/25](https://docs.google.com/document/d/1mCVoli3fbEGMQDapyApV4kf1rHfJE38Rl4wJV6Jg0WM))

![MVP Scope Architecture](./images/image4.png)

---

## Workflow Overview

### Phase 1: Event Trigger (Sentinel → Adapter)

1. Sentinel polls HyperFleet API every 5s
2. Detects cluster with dependencies complete (Validation, DNS, Placement)
3. Publishes `cluster.create` CloudEvent to message broker
4. Pull Secret Adapter consumes event from its subscription

![Workflow Phase 1 - Event Trigger](./images/image1.png)

### Phase 2: Precondition Evaluation (Adapter)

5. Adapter fetches cluster details from API: `GET /clusters/{id}`
6. Evaluates preconditions using Expr expressions:
   - `spec.provider == "gcp"`
   - `spec.gcp.projectId != nil` (RH project)
   - `spec.pullSecret.data != nil` (pull secret JSON exists - Hardcoded Pull Secret)
   - `status.adapters[validation].available == "True"`
   - `status.adapters[dns].available == "True"`
   - `status.adapters[placement].available == "True"`
7. If all preconditions pass, proceed; otherwise skip event

### Phase 3: Resource Creation (Adapter → Kubernetes)

8. Create Kubernetes Secret containing pull secret data
   - **Namespace:** `hyperfleet-system`
   - **Name:** `cluster-{cluster-id}-pullsecret-data`
   - **Purpose:** Used by Job as input

9. Create Kubernetes Job to execute provisioning
   - **Name:** `pullsecret-{cluster-id}-gen{generation}`
   - **Service Account:** `pullsecret-adapter-job` (provided by RH project)
   - **Environment:** Cluster ID, GCP project ID, pull secret data, namespace

### Phase 4: GCP Secret Manager Storage (Job)

10. Job authenticates
    - Kubernetes Service Account token exchanged for GCP access token

11. Job checks if secret exists in GCP Secret Manager
    - `GetSecret(projects/{RH-project}/secrets/hyperfleet-{cluster-id}-pull-secret)`

12. If secret doesn't exist, create it:
    - `CreateSecret()` with labels: `managed-by=hyperfleet`, `cluster-id={id}`
    - Replication: Automatic (GCP-managed)

13. Add secret version with pull secret data:
    - `AddSecretVersion(payload: pull-secret-json)`
    - GCP returns version number (e.g., `1`, `2`, etc.)

14. Verify secret accessibility:
    - `AccessSecretVersion(latest)` to confirm readability

---

## Roll-out Plan

To minimize the risks related to this, rollout will be done in different milestones:

- **M1:** Pull Secret Service for MVP scope
- **M2:** Pull Secret Service to extract out quay functionality from AMS
- **M3:** Pull Secret Service to support for other clouds and registries

---

## References

- [RACI Matrix for Pull Secret Service](https://docs.google.com/spreadsheets/d/1EfsZ0QoUkaf_YOSDA8k2fKHS645l5H3sWfKit1KBu1g/edit?gid=0#gid=0)
- [Tollbooth v2.0 - Use cases](https://docs.google.com/document/d/17begbwlBjU0UpUUgTkwRc6pIS9qNn51sA3WGkwit1Mo/edit?tab=t.0#heading=h.edf6b1rxiby4)
- https://github.com/openshift-hyperfleet/architecture
- [Miro Board 1](https://miro.com/app/board/uXjVJy-n5k4=/)
- [Miro Board 2](https://miro.com/app/board/uXjVJNpPkZ0=/)
- https://hypershift-docs.netlify.app/
- https://rh-amarin.github.io/hyperfleet-architecture/hyperfleet/architecture/sequence.html

---

**Document Version:** 1.0
**Last Updated:** 2025-12-02
**Maintained By:** HyperFleet Platform Team
