# Pull Secret Workflow and Implementation Plan

---

## Table of Contents

1. [Overview](#overview)
2. [High-Level Architecture](#high-level-architecture)
3. [Workflow 1: Store Secret in GCP Secret Manager](#workflow-1-store-secret-in-gcp-secret-manager)

---

## Overview

### Purpose

The Pull Secret Adapter manages image registry pull secrets for HyperShift-managed OpenShift clusters. It orchestrates two primary workflows:

1. **GCP Secret Manager Storage**: Store pull secrets securely in the customer's GCP Secret Manager
2. **Kubernetes Secret Provisioning**: Create pull secrets in the management cluster namespace for HyperShift to access

### Key Principles

- **Customer Data Security**: Pull secrets stored in the customer's GCP project
- **Separation of Concerns**: Adapter orchestrates; Job executes
- **Event-Driven**: Triggered by CloudEvents from Sentinel
- **Status-Driven**: Reports status to HyperFleet API for Sentinel decision-making

### Components Involved

| Component | Responsibility | Location |
|-----------|---------------|----------|
| **Sentinel** | Publishes cluster events | Red Hat management cluster |
| **Pull Secret Adapter** | Orchestrates secret provisioning | Red Hat management cluster |
| **Pull Secret Job** | Executes GCP API calls | Red Hat management cluster (runs as Job) |
| **GCP Secret Manager** | Stores pull secret data | Customer's GCP project |
| **Kubernetes Secret** | Provides pull secret to HyperShift | Management cluster namespace |
| **HyperFleet API** | Receives status updates | Red Hat management cluster |

---

## High-Level Architecture

```mermaid
graph TB
    subgraph "Red Hat Management Cluster"
        Sentinel[Sentinel Service]
        Broker[Message Broker<br/>GCP Pub/Sub]
        Adapter[Pull Secret Adapter]
        API[HyperFleet API]

        subgraph "Pull Secret Job Execution"
            Job[Pull Secret Job Pod]
            K8sSecret[Kubernetes Secret<br/>management-ns/pull-secret]
        end
    end

    subgraph "Customer GCP Project"
        GCPSecret[GCP Secret Manager<br/>hyperfleet-cls-123-pull-secret]
        GCPSA[GCP Service Account<br/>pullsecret-manager]
    end

    subgraph "HyperShift"
        HostedCluster[HostedCluster CR]
        ControlPlane[Control Plane Pods]
        WorkerNodes[Worker Nodes]
    end

    %% Workflow connections
    Sentinel -->|1. Publish cluster.create| Broker
    Broker -->|2. Deliver event| Adapter
    Adapter -->|3. GET cluster details| API
    Adapter -->|4. Create Job| Job

    Job -->|5a. Use Workload Identity| GCPSA
    GCPSA -->|5b. Create/Update| GCPSecret

    Job -->|6. Create K8s Secret| K8sSecret
    Adapter -->|7. POST status| API

    HostedCluster -.->|Reference| K8sSecret
    ControlPlane -.->|Pull images| K8sSecret
    WorkerNodes -.->|Pull images via control plane| GCPSecret

    classDef redhat fill:#e00,color:#fff
    classDef customer fill:#0066cc,color:#fff
    classDef hypershift fill:#0a0,color:#fff

    class Sentinel,Broker,Adapter,API,Job,K8sSecret redhat
    class GCPSecret,GCPSA customer
    class HostedCluster,ControlPlane,WorkerNodes hypershift
```

### Architecture Flow Summary

1. **Event Trigger**: Sentinel publishes `cluster.create` event
2. **Adapter Receives**: Pull Secret Adapter consumes event from broker
3. **Precondition Check**: Adapter fetches cluster details and validates dependencies
4. **Job Creation**: Adapter creates Pull Secret Job with cluster context
5. **GCP Storage**: Job stores pull secret in customer's GCP Secret Manager
6. **K8s Secret Creation**: Job creates Kubernetes Secret in management cluster
7. **Status Report**: Adapter monitors Job and reports status to API

---

## Workflow 1: Store Secret in GCP Secret Manager

### Objective

Store the pull secret data in the customer's GCP Secret Manager for worker node access.

### Detailed Flow Diagram

```mermaid
sequenceDiagram
    autonumber

    participant Sentinel
    participant Broker as Message Broker
    participant Adapter as Pull Secret Adapter
    participant API as HyperFleet API
    participant Job as Pull Secret Job
    participant K8s as Kubernetes API
    participant WI as Workload Identity
    participant GCPSA as GCP Service Account
    participant SM as GCP Secret Manager

    %% Event trigger
    Sentinel->>API: GET /clusters
    API-->>Sentinel: [{id: cls-123, ...}]
    Sentinel->>Sentinel: Evaluate: DNS, Validation,<br/>Placement all Available
    Sentinel->>Broker: Publish cluster.create event

    %% Adapter receives and validates
    Broker->>Adapter: Deliver CloudEvent
    Adapter->>API: GET /clusters/cls-123
    API-->>Adapter: {spec: {gcp: {projectId}, pullSecret: {data}}}

    Adapter->>Adapter: Evaluate preconditions:<br/>✓ provider == gcp<br/>✓ projectId exists<br/>✓ pullSecret.data exists<br/>✓ dependencies complete

    %% Create Kubernetes resources
    Adapter->>K8s: Create Secret<br/>cluster-cls-123-pullsecret-data
    K8s-->>Adapter: Secret created

    Adapter->>K8s: Create Job<br/>pullsecret-cls-123-gen1
    K8s-->>Adapter: Job created

    %% Job execution - GCP Secret Manager
    K8s->>Job: Start Pod
    Job->>Job: Read env vars:<br/>GCP_PROJECT_ID<br/>SECRET_NAME<br/>PULL_SECRET_DATA

    Job->>WI: Request GCP token
    WI->>WI: Verify K8s SA:<br/>pullsecret-adapter-job
    WI->>GCPSA: Exchange for GCP token<br/>(customer project)
    GCPSA-->>WI: GCP access token
    WI-->>Job: Token for customer project

    Job->>SM: GetSecret(hyperfleet-cls-123-pull-secret)
    alt Secret doesn't exist
        SM-->>Job: NotFound
        Job->>SM: CreateSecret()<br/>labels: managed-by=hyperfleet
        SM-->>Job: Secret resource created
    else Secret exists
        SM-->>Job: Secret metadata
        Job->>Job: Log: Secret already exists
    end

    Job->>SM: AddSecretVersion(data: pull-secret-json)
    SM-->>Job: Version created (version: 1)

    Job->>SM: AccessSecretVersion(latest)
    SM-->>Job: Verify data accessible

    Job->>Job: Success - exit 0

    %% Status reporting
    K8s->>Adapter: Job status: Complete
    Adapter->>API: POST /clusters/cls-123/statuses<br/>{adapter: pullsecret,<br/>conditions: {available: True}}
    API-->>Adapter: 201 Created
```

### Workflow Steps

#### Phase 1: Event Reception and Validation (Steps 1-6)

1. **Sentinel Polling**: Sentinel polls HyperFleet API for clusters
2. **Decision Logic**: Evaluates that DNS, Validation, Placement adapters are complete
3. **Event Publishing**: Publishes `cluster.create` CloudEvent to broker
4. **Event Delivery**: Broker delivers event to Pull Secret Adapter subscription
5. **Cluster Fetch**: Adapter fetches full cluster details from API
6. **Precondition Evaluation**: Adapter checks:
   - `spec.provider == "gcp"`
   - `spec.gcp.projectId != nil`
   - `spec.pullSecret.data != nil`
   - `status.adapters[validation].available == "True"`
   - `status.adapters[dns].available == "True"`
   - `status.adapters[placement].available == "True"`

#### Phase 2: Resource Creation (Steps 7-9)

7. **K8s Secret Creation**: Adapter creates temporary Kubernetes Secret containing pull secret data
   - Name: `cluster-cls-123-pullsecret-data`
   - Namespace: `hyperfleet-system`
   - Data: Pull secret JSON from cluster spec

8. **Job Creation**: Adapter creates Kubernetes Job
   - Name: `pullsecret-cls-123-gen1` (includes generation ID)
   - Service Account: `pullsecret-adapter-job` (with Workload Identity)
   - Environment: `GCP_PROJECT_ID`, `SECRET_NAME`, `PULL_SECRET_DATA`

