# HyperFleet Cluster Status JSON Guide

**Purpose**: Comprehensive guide to understanding cluster status JSON structure and adapter status contract

---

## Overview

HyperFleet uses a **condition-based status reporting contract** where adapters report their progress through standardized Kubernetes-style conditions. This guide explains:

1. **The REST API** - Endpoints for reading and updating cluster status
2. **The Adapter → API Contract** - Required payload structure for status updates
3. **The Three Required Conditions** - Available, Applied, Health
4. **How to Read Cluster Status** - Interpreting aggregated cluster state
5. **Common Patterns** - Polling, error handling, progress tracking

---

## REST API Summary

### Resource Hierarchy

```
/v1/clusters/{clusterId}                    # Cluster resource (with aggregated status)
/v1/clusters/{clusterId}/statuses           # ClusterStatus resource (detailed adapter statuses)
```

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| **GET** | `/v1/clusters/{clusterId}` | Get cluster with aggregated status (phase + adapter availability) |
| **GET** | `/v1/clusters/{clusterId}/statuses` | Get the ClusterStatus with all adapter statuses |
| **POST** | `/v1/clusters/{clusterId}/statuses` | Create the ClusterStatus (first adapter reporting) |
| **PATCH** | `/v1/clusters/{clusterId}/statuses/{statusId}` | Update a specific adapter's status in the ClusterStatus |

### Adapter Status Update Flow (Upsert Pattern)

When an adapter needs to report its status, it follows this **upsert pattern**:

#### Step 1: Try to GET existing ClusterStatus

**GET** `/v1/clusters/{clusterId}/statuses`

**Responses**:
- **200 OK** - ClusterStatus exists, returns the status object with its `id`
- **404 Not Found** - No ClusterStatus exists yet for this cluster

#### Step 2a: If 404 → POST to create

**POST** `/v1/clusters/{clusterId}/statuses`

**Request Body**:
```json
{
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "JobRunning",
          "message": "Job is executing",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Job created successfully",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "Adapter is healthy",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        }
      ],
      "metadata": {
        "jobName": "validation-cls-123-gen1"
      },
      "lastUpdated": "2025-10-17T12:00:05Z"
    }
  ]
}
```

**Response**: `201 Created` with the created ClusterStatus object (including its `id`)

#### Step 2b: If 200 → PATCH to update

**PATCH** `/v1/clusters/{clusterId}/statuses/{statusId}`

**Request Body**:
```json
{
  "adapter": "validation",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Job created successfully",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true
    }
  },
  "metadata": {
    "jobName": "validation-cls-123-gen1"
  },
  "lastUpdated": "2025-10-17T12:02:00Z"
}
```

**What Happens**:
1. API finds the adapter entry in `adapterStatuses` array (or creates if first time)
2. API updates/replaces that adapter's status with the new payload
3. API updates ClusterStatus `lastUpdated` timestamp
4. API recalculates Cluster aggregated status (phase + adapters array)

**Response**: `200 OK` with updated ClusterStatus object

### Adapter Implementation Pattern

```
function reportStatus(clusterId, adapterStatus) {
  // Try GET
  response = GET /v1/clusters/{clusterId}/statuses

  if (response.status == 404) {
    // ClusterStatus doesn't exist, create it
    POST /v1/clusters/{clusterId}/statuses
    body = {
      adapterStatuses: [adapterStatus]
    }
  } else {
    // ClusterStatus exists, update our adapter's entry
    statusId = response.data.id
    PATCH /v1/clusters/{clusterId}/statuses/{statusId}
    body = adapterStatus
  }
}
```

**Note**: The `adapterStatus` object includes `observedGeneration` which tells the API what generation of the cluster spec this adapter has reconciled.

### Alternative: Sub-resource Approach

Some APIs might prefer treating adapter status as a sub-resource:

**PUT** `/v1/clusters/{clusterId}/statuses/adapters/{adapterName}`

This is more explicit but results in a longer URL path. Both approaches are valid REST patterns.

---

## The Adapter Status Contract

### Reporting Status: POST or PATCH

Adapters use the **upsert pattern** described above. The payload structure for adapter status is the same whether POSTing (to create) or PATCHing (to update).

### Adapter Status Payload Structure

When POSTing to create a new ClusterStatus, include the full structure:
```json
{
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [...],
      "data": {...},
      "metadata": {...},
      "lastUpdated": "2025-10-17T12:00:05Z"
    }
  ]
}
```

Note: No `generation` field on ClusterStatus itself. Each adapter reports its own `observedGeneration`.

When PATCHing an existing ClusterStatus, send just the adapter status:

```json
{
  "adapter": "validation",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true,
      "quotaSufficient": true
    }
  },
  "metadata": {
    "jobName": "validation-cls-123-gen1",
    "executionTime": "115s"
  },
  "lastUpdated": "2025-10-17T12:02:00Z"
}
```

### ClusterStatus Object Structure

The ClusterStatus object is a **RESTful resource** that contains ALL adapter statuses for a cluster in one place:

```json
{
  "id": "status-cls-550e8400",
  "type": "clusterStatus",
  "href": "/api/hyperfleet/v1/clusters/cls-550e8400/statuses",
  "clusterId": "cls-550e8400",
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "JobSucceeded",
          "message": "Job completed successfully after 115 seconds",
          "lastTransitionTime": "2025-10-17T12:02:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job created successfully",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "AllChecksPassed",
          "message": "All validation checks passed",
          "lastTransitionTime": "2025-10-17T12:02:00Z"
        }
      ],
      "data": {
        "validationResults": {
          "route53ZoneFound": true,
          "s3BucketAccessible": true,
          "quotaSufficient": true
        }
      },
      "metadata": {
        "jobName": "validation-cls-123-gen1",
        "executionTime": "115s"
      },
      "lastUpdated": "2025-10-17T12:02:00Z"
    },
    {
      "adapter": "dns",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "AllRecordsCreated",
          "message": "All DNS records created and verified",
          "lastTransitionTime": "2025-10-17T12:05:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "DNS Job created successfully",
          "lastTransitionTime": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "DNS adapter executed without errors",
          "lastTransitionTime": "2025-10-17T12:05:00Z"
        }
      ],
      "data": {
        "recordsCreated": ["api.my-cluster.example.com", "*.apps.my-cluster.example.com"]
      },
      "lastUpdated": "2025-10-17T12:05:00Z"
    }
  ],
  "lastUpdated": "2025-10-17T12:05:00Z"
}
```

### ClusterStatus Fields

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `id` | **YES** | string | Unique ID for this ClusterStatus object |
| `type` | **YES** | string | Always "clusterStatus" |
| `href` | **YES** | string | API path to this ClusterStatus resource |
| `clusterId` | **YES** | string | ID of the cluster this status belongs to |
| `adapterStatuses` | **YES** | array | Array of adapter status objects |
| `lastUpdated` | **YES** | timestamp | When this ClusterStatus was last updated |

### AdapterStatus Fields (within adapterStatuses array)

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `adapter` | **YES** | string | Adapter name (e.g., "validation", "dns") |
| `observedGeneration` | **YES** | integer | Cluster generation this adapter reconciled |
| `conditions` | **YES** | array | **Minimum 3 conditions** (Available, Applied, Health) |
| `data` | **NO** | JSONB | Adapter-specific structured data (optional) |
| `metadata` | **NO** | object | Additional metadata (optional) |
| `lastUpdated` | **YES** | timestamp | When this adapter status was last updated |

**Key Points**:
- **ONE ClusterStatus object per cluster** - All adapter statuses grouped together
- ClusterStatus does NOT have a generation field - it reflects current observed state
- Each adapter in `adapterStatuses` has `observedGeneration` indicating which cluster generation it has reconciled
- Cluster spec has `generation` (user's intent), adapters report `observedGeneration` (observed state)
- Adapters use upsert pattern: GET to check if exists → POST to create or PATCH to update
- First adapter to report typically POSTs to create the ClusterStatus
- Subsequent updates use PATCH to update specific adapter entries in `adapterStatuses` array
- This is much more RESTful: `/clusters/{id}/statuses` represents the complete status of the cluster
- Prevents scattered status objects - everything in one cohesive resource
- The Cluster object still contains only aggregated status (see below)

---

## The Three Required Conditions

Every adapter status update **MUST** include these three conditions:

### 1. Available

**Purpose**: Has the adapter completed its work successfully? 

**Important**: The adapter aggregates this value based on all its other conditions 

**Meaning**:
- `True` - Adapter finished successfully, all requirements met
- `False` - Adapter failed, incomplete, or still in progress

**Examples**:
```json
// Success
{
  "type": "Available",
  "status": "True",
  "reason": "JobSucceeded",
  "message": "Validation Job completed successfully",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}

// Failure
{
  "type": "Available",
  "status": "False",
  "reason": "JobFailed",
  "message": "Validation failed: Route53 zone not found for domain example.com",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}

// In Progress
{
  "type": "Available",
  "status": "False",
  "reason": "JobRunning",
  "message": "Validation Job is still executing",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}
```

### 2. Applied

**Purpose**: Has the adapter created/applied the Kubernetes resources it needs?

**Meaning**:
- `True` - Resources created successfully (Job launched, ConfigMap applied, etc.)
- `False` - Failed to create resources or not yet attempted

**Examples**:
```json
// Job Created
{
  "type": "Applied",
  "status": "True",
  "reason": "JobLaunched",
  "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}

// Creation Failed
{
  "type": "Applied",
  "status": "False",
  "reason": "ResourceQuotaExceeded",
  "message": "Failed to create Job: namespace quota exceeded",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}

// Not Yet Attempted
{
  "type": "Applied",
  "status": "False",
  "reason": "PreconditionsNotMet",
  "message": "Waiting for validation to complete",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}
```

### 3. Health

**Purpose**: Did anything unexpected or concerning happen?

**Meaning**:
- `True` - No unexpected errors, adapter is healthy
- `False` - Unexpected error occurred (retries exhausted, resource not found, etc.)

**Key Point**: Health is about **unexpected errors**, not business logic failures.

**Examples**:
```json
// Healthy (even if validation fails business logic)
{
  "type": "Health",
  "status": "True",
  "reason": "AllChecksPassed",
  "message": "Adapter executed normally without errors",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}

// Unhealthy (unexpected error)
{
  "type": "Health",
  "status": "False",
  "reason": "UnexpectedError",
  "message": "Failed to connect to Kubernetes API after 3 retries",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}

// Unhealthy (resource missing)
{
  "type": "Health",
  "status": "False",
  "reason": "ResourceNotFound",
  "message": "Job 'validation-cls-123-gen1' not found in cluster",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}
```

---

## Additional Conditions (Optional)

Adapters **MAY** send additional conditions beyond the three required ones. These can provide more granular status information.

### Rules for Additional Conditions

1. **All conditions must be positive assertions**
   - GOOD: `DNSRecordsCreated` (status: True/False)
   - BAD: `DNSRecordsNotCreated` (confusing when status: False)

2. **Adapter aggregates all conditions to determine Available**
   - If any condition is False, Available should be False
   - If all conditions are True, Available should be True

### Example: DNS Adapter with Additional Conditions

This example shows an adapter status payload (what gets PUT to the API and stored in the ClusterStatus `adapterStatuses` array):

```json
{
  "adapter": "dns",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "AllRecordsCreated",
      "message": "All DNS records created and verified",
      "lastTransitionTime": "2025-10-17T12:05:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "DNS Job created successfully",
      "lastTransitionTime": "2025-10-17T12:03:00Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "DNS adapter executed without errors",
      "lastTransitionTime": "2025-10-17T12:05:00Z"
    },
    // Additional conditions
    {
      "type": "APIRecordCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created A record for api.my-cluster.example.com",
      "lastTransitionTime": "2025-10-17T12:04:30Z"
    },
    {
      "type": "AppsWildcardCreated",
      "status": "True",
      "reason": "Route53Updated",
      "message": "Created wildcard record for *.apps.my-cluster.example.com",
      "lastTransitionTime": "2025-10-17T12:04:45Z"
    }
  ]
}
```

**Aggregation Logic**:
- If any sub-condition is `False`, `Available` should be `False`
- If all sub-conditions are `True`, `Available` should be `True`
- Default to `False` if no other conditions exist

---

## The Data Field (Optional)

The `data` field is a **JSONB object** that adapters can use to send structured information beyond conditions.

### When to Use Data

- Detailed results that don't fit in condition messages
- Structured information for debugging
- Resource identifiers (VPC IDs, IAM role ARNs, etc.)
- Metrics and timing information

### Examples

**Validation Adapter Data**:
```json
{
  "data": {
    "validationResults": {
      "route53": {
        "zoneId": "Z1234567890ABC",
        "zoneName": "example.com",
        "found": true
      },
      "s3": {
        "bucketName": "hyperfleet-clusters",
        "accessible": true,
        "region": "us-east-1"
      },
      "quotas": {
        "vpcLimit": 5,
        "vpcUsed": 2,
        "sufficient": true
      }
    },
    "checksPerformed": 15,
    "checksPassed": 15,
    "checksFailed": 0
  }
}
```

**Infrastructure Adapter Data**:
```json
{
  "data": {
    "resources": {
      "vpcId": "vpc-123abc456def",
      "subnetIds": ["subnet-111", "subnet-222", "subnet-333"],
      "securityGroupId": "sg-789ghi",
      "natGatewayId": "nat-012jkl"
    },
    "timing": {
      "vpcCreation": "12s",
      "subnetCreation": "8s",
      "totalTime": "45s"
    }
  }
}
```

---

## YAML Aggregation Configuration

HyperFleet uses **configuration-driven status aggregation** to determine cluster phases and conditions from adapter statuses. This allows flexible customization of aggregation rules without code changes.

The system uses **[expr-lang/expr](https://expr-lang.org/)**, a powerful expression evaluation library, to evaluate conditions. This provides maximum flexibility while maintaining safety guarantees (memory-safe, side-effect-free, always-terminating).

### Configuration Structure

The aggregation configuration is defined in YAML format and specifies:

1. **Required adapters** for each phase
2. **Phase transition rules** based on adapter conditions
3. **Cluster condition generation** rules using expr expressions
4. **Timeout and retry policies**

### Example Aggregation Configuration

```yaml
# config/aggregation.yaml
# Required adapters that must complete before cluster is considered ready
requiredAdapters:
  - validation
  - dns
  - infrastructure
  - hypershift

# Optional adapters (failures don't block cluster ready state)
optionalAdapters:
  - monitoring
  - logging

# Pub/Sub configuration for adapter notifications
pubsub:
  provider: "rabbitmq"  # or "gcp-pubsub"
  topics:
    clusterEvents: "hyperfleet.cluster.events"
    statusUpdates: "hyperfleet.status.updates"
  retryPolicy:
    maxRetries: 3
    retryInterval: "30s"

# Cluster conditions generation rules
# These define HOW to evaluate each condition using expr expressions AND the reason/message templates
clusterConditions:
  - type: "AllAdaptersReady"
    evaluate:
      expr: 'all(requiredAdapters, {.available == "True"})'
    templates:
      true:
        reason: "AllRequiredAdaptersAvailable"
        message: "All required adapters completed successfully"
      false:
        reason: "RequiredAdaptersNotReady"
        message: "{{.FailedCount}} of {{.TotalCount}} required adapters not ready: {{.FailedAdapterNames}}"

  - type: "AdaptersUnhealthy"
    evaluate:
      expr: 'any(allAdapters, {.health == "False"})'
    templates:
      true:
        reason: "HealthCheckFailures"
        message: "{{.UnhealthyAdapterNames}} experiencing health issues"
      false:
        reason: "AllAdaptersHealthy"
        message: "All adapters are healthy"

  - type: "AdaptersFailed"
    evaluate:
      expr: 'any(requiredAdapters, {.available == "False" && .health == "True"})'
    templates:
      true:
        reason: "RequiredAdapterFailure"
        message: "Required adapters failed: {{.FailedAdapterNames}}. {{.FirstFailureMessage}}"
      false:
        reason: "NoAdapterFailures"
        message: "No required adapter failures detected"

  - type: "ProvisioningInProgress"
    evaluate:
      expr: 'any(allAdapters, {.applied == "True" && .available == "False"})'
    templates:
      true:
        reason: "AdaptersWorking"
        message: "{{.WorkingCount}} of {{.TotalCount}} adapters actively provisioning resources"
      false:
        reason: "NoActiveProvisioning"
        message: "No adapters currently provisioning"

  - type: "AllAdaptersReporting"
    evaluate:
      expr: 'all(requiredAdapters, {.observedGeneration == currentGeneration})'
    templates:
      true:
        reason: "AllAdaptersReported"
        message: "All required adapters reported status for current generation"
      false:
        reason: "AdaptersNotStarted"
        message: "Waiting for adapters to begin processing cluster request"

  - type: "ValidationPassed"
    evaluate:
      expr: 'adapters["validation"].available == "True"'
    templates:
      true:
        reason: "AllValidationChecksPassed"
        message: "Validation adapter completed all checks successfully"
      false:
        reason: "ValidationFailed"
        message: "{{.AdapterFailureMessage}}"

  - type: "InfrastructureReady"
    evaluate:
      expr: 'adapters["infrastructure"].available == "True"'
    templates:
      true:
        reason: "AllResourcesProvisioned"
        message: "Infrastructure adapter provisioned all required resources"
      false:
        reason: "InfrastructureNotReady"
        message: "{{.AdapterFailureMessage}}"

  - type: "DNSConfigured"
    evaluate:
      expr: 'adapters["dns"].available == "True"'
    templates:
      true:
        reason: "AllRecordsCreated"
        message: "DNS adapter created all required records"
      false:
        reason: "DNSNotConfigured"
        message: "{{.AdapterFailureMessage}}"

# Phase evaluation rules (phases evaluated in hardcoded priority order)
# Note: Phase priority is hardcoded in business logic, not configured here
# Phases reference clusterConditions defined above - no duplication!
phases:
  degraded:
    description: "Cluster operational but with health issues"
    requiredConditions:
      - type: "AdaptersUnhealthy"
        status: "True"

  failed:
    description: "One or more required adapters failed"
    requiredConditions:
      - type: "AdaptersFailed"
        status: "True"

  ready:
    description: "All required adapters completed successfully"
    requiredConditions:
      - type: "AllAdaptersReady"
        status: "True"
      - type: "ValidationPassed"
        status: "True"

  provisioning:
    description: "One or more adapters are actively provisioning resources"
    requiredConditions:
      - type: "ProvisioningInProgress"
        status: "True"

  pending:
    description: "Waiting for adapters to start processing"
    requiredConditions:
      - type: "AllAdaptersReporting"
        status: "False"

# Error handling and policies
policies:
  staleThreshold: "10m"  # Consider status stale after 10 minutes
  staleAction: "degraded"  # Move to degraded if stale
  maxRetries: 3
  retryInterval: "30s"

# Default behavior for missing adapters
defaultBehavior:
  missingAdapter: "pending"    # Default to pending phase
  timeout: "10m"              # Wait timeout before marking failed
```

### Configuration Loading

The aggregation configuration is loaded at API startup.

### Custom Aggregation Rules

Organizations can provide custom aggregation configurations by:

1. **Environment-specific configs** - Different rules for dev/staging/prod
2. **Cluster-type configs** - Different rules for different workload types
3. **Tenant-specific configs** - Multi-tenant environments with custom rules

---

## Cluster and Status Objects

The HyperFleet API provides two endpoints for cluster information:

- **GET** `/v1/clusters/{id}` - Cluster resource with metadata and aggregated status
- **GET** `/v1/clusters/{id}/statuses` - Detailed adapter statuses (ClusterStatus resource)

### Cluster Object Structure (with Aggregated Status)

**GET** `/v1/clusters/{id}`

Returns the complete cluster resource including metadata, spec, and aggregated status:

```json
{
  "id": "cls-550e8400",
  "name": "my-cluster",
  "generation": 1,
  "spec": {
    "cloud": "aws",
    "region": "us-east-1",
    "domain": "example.com",
    "networking": {
      "clusterNetwork": "10.128.0.0/14",
      "serviceNetwork": "172.30.0.0/16"
    },
    "hypershift": {
      "version": "4.14.0",
      "releaseImage": "quay.io/openshift-release-dev/ocp-release:4.14.0"
    }
  },
  "metadata": {
    "createdAt": "2025-10-17T12:00:00Z",
    "updatedAt": "2025-10-17T12:05:00Z",
    "labels": {
      "environment": "production",
      "team": "platform"
    }
  },
  "status": {
    "phase": "Ready",
    "phaseDescription": "All required adapters completed successfully",
    "conditions": [
      {
        "type": "AllAdaptersReady",
        "status": "True",
        "reason": "AllRequiredAdaptersAvailable",
        "message": "All required adapters completed successfully",
        "lastTransitionTime": "2025-10-17T12:05:00Z"
      },
      {
        "type": "ValidationPassed",
        "status": "True",
        "reason": "AllValidationChecksPassed",
        "message": "Validation adapter completed all checks successfully",
        "lastTransitionTime": "2025-10-17T12:02:00Z"
      },
      {
        "type": "InfrastructureReady",
        "status": "True",
        "reason": "AllResourcesProvisioned",
        "message": "Infrastructure adapter provisioned all required resources",
        "lastTransitionTime": "2025-10-17T12:04:30Z"
      },
      {
        "type": "DNSConfigured",
        "status": "True",
        "reason": "AllRecordsCreated",
        "message": "DNS adapter created all required records",
        "lastTransitionTime": "2025-10-17T12:05:00Z"
      }
    ],
    "adapters": [
      {
        "name": "validation",
        "available": "True",
        "observedGeneration": 1
      },
      {
        "name": "dns",
        "available": "True",
        "observedGeneration": 1
      },
      {
        "name": "infrastructure",
        "available": "True",
        "observedGeneration": 1
      },
      {
        "name": "hypershift",
        "available": "True",
        "observedGeneration": 1
      }
    ],
    "lastUpdated": "2025-10-17T12:05:00Z"
  }
}
```

### Aggregated Status Fields

The `status` field in the cluster object contains the aggregated status computed from all adapter statuses:

| Field | Type | Description |
|-------|------|-------------|
| `phase` | string | Overall cluster state: "Pending", "Provisioning", "Ready", "Failed", or "Degraded" |
| `phaseDescription` | string | Human-readable phase description from configuration |
| `conditions` | array | Cluster-level conditions (generated by expr evaluation) |
| `adapters` | array | Summary of each adapter's status (name, available, observedGeneration) |
| `lastUpdated` | timestamp | When the aggregated status was last updated |

### Status Phases

The `phase` field represents the overall cluster state based on adapter statuses and is calculated using the aggregation configuration:

#### 1. **Pending**
- **When**: Cluster created but adapters haven't started processing yet
- **Condition**: No adapters have reported status or all are waiting for preconditions
- **Example**: Cluster just created, validation adapter hasn't started

```json
{
  "phase": "Pending",
  "phaseDescription": "Waiting for adapters to start processing",
  "conditions": [
    {
      "type": "AllAdaptersReporting",
      "status": "False",
      "reason": "AdaptersNotStarted",
      "message": "Waiting for adapters to begin processing cluster request"
    }
  ]
}
```

#### 2. **Provisioning**
- **When**: One or more adapters are actively working
- **Condition**: At least one adapter has `Applied: True` but `Available: False`
- **Example**: Validation completed, DNS adapter running

```json
{
  "phase": "Provisioning",
  "phaseDescription": "One or more adapters are actively provisioning resources",
  "conditions": [
    {
      "type": "ProvisioningInProgress",
      "status": "True",
      "reason": "AdaptersWorking",
      "message": "2 of 4 adapters actively provisioning resources"
    }
  ]
}
```

#### 3. **Ready**
- **When**: All required adapters completed successfully
- **Condition**: All required adapters have `Available: True` and `Health: True` for current generation
- **Example**: All adapters finished without errors

```json
{
  "phase": "Ready",
  "phaseDescription": "All required adapters completed successfully",
  "conditions": [
    {
      "type": "AllAdaptersReady",
      "status": "True",
      "reason": "AllRequiredAdaptersAvailable",
      "message": "All required adapters completed successfully"
    }
  ]
}
```

#### 4. **Failed**
- **When**: One or more required adapters failed (business logic failure)
- **Condition**: Any required adapter has `Available: False` with `Health: True`
- **Example**: Validation failed due to missing DNS zone

```json
{
  "phase": "Failed",
  "phaseDescription": "One or more required adapters failed",
  "conditions": [
    {
      "type": "AdaptersFailed",
      "status": "True",
      "reason": "RequiredAdapterFailure",
      "message": "Validation failed: Route53 zone not found for domain example.com"
    }
  ]
}
```

#### 5. **Degraded**
- **When**: Cluster operational but has health issues
- **Condition**: Any adapter has `Health: False` (unexpected errors)
- **Example**: Infrastructure completed but monitoring adapter has connection issues

```json
{
  "phase": "Degraded",
  "phaseDescription": "Cluster operational but with health issues",
  "conditions": [
    {
      "type": "AdaptersUnhealthy",
      "status": "True",
      "reason": "HealthCheckFailures",
      "message": "Monitoring adapter experiencing API connection failures"
    }
  ]
}
```

### Phase Calculation Logic

The phase is determined by evaluating adapter statuses using **hardcoded priority logic**:

```
1. Get aggregation config for cluster type
2. Evaluate phases in fixed priority order:
   - degraded (any adapter Health: False) - HIGHEST PRIORITY
   - failed (any required adapter business failure)
   - ready (all required adapters Available: True)
   - provisioning (any adapter actively working)
   - pending (default/fallback state) - LOWEST PRIORITY
3. Generate cluster conditions based on configurable rules
4. Set phase and conditions on cluster status
```

**Key Design Decision:** Phase priority is **hardcoded in business logic**, not configurable. This ensures critical states like "Degraded" are never hidden by configuration mistakes, and provides consistent, predictable behavior across all environments.

### Phase Transitions

Valid phase transitions follow this flow:

```
Pending → Provisioning → Ready
    ↓           ↓          ↓
  Failed    Failed     Degraded
    ↓           ↓          ↓
Provisioning → Ready   Ready
```

**Key principles**:
- **Pending** is the initial state
- **Failed** can transition back to **Provisioning** (retry scenarios)
- **Degraded** indicates operational but with issues
- **Ready** is the target end state

### Accessing Detailed Status

To see detailed conditions, data, and health information for ALL adapters:

**GET** `/v1/clusters/{clusterId}/statuses`

This returns the complete ClusterStatus object containing all adapter statuses in the `adapterStatuses` array. You can then filter client-side for the specific adapter you need.

Each adapter in the `adapterStatuses` array includes its `observedGeneration` field, indicating which cluster generation that adapter has reconciled.

### Check If Adapter Completed

To determine if an adapter has completed successfully:
1. Get the cluster object: `GET /v1/clusters/{clusterId}`
2. Look in `status.adapters` array for the adapter
3. Check `observedGeneration === cluster.generation` (not stale)
4. Check `available === "True"`

### Check Adapter Health

To check adapter health, you need the detailed ClusterStatus object:
1. Fetch: `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
2. Find the adapter in the `adapterStatuses` array
3. Find the `Health` condition in that adapter's conditions
4. Check if `status === "True"`

If `Health: False`, examine the `message` and `data` fields for debugging details.

---

## Configuration-driven Aggregation

HyperFleet's status aggregation system uses **rule-based evaluation** to determine cluster phase and conditions from adapter statuses. This section explains how the aggregation engine processes configurations and adapter data.

### Aggregation Engine Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Detailed      │    │   Aggregation    │    │   Aggregated    │
│   Statuses      │───→│     Engine       │───→│    Status       │
│                 │    │                  │    │                 │
│ /statuses       │    │ • Expr Evaluator │    │ cluster.status  │
│ • Full conditions│   │ • Field Extract  │    │ • phase         │
│ • JSONB data    │    │ • Condition Gen  │    │ • conditions    │
│ • Metadata      │    │ • Phase Calc     │    │ • adapters[]    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              ↑
                       ┌──────────────────┐
                       │  YAML Config     │
                       │                  │
                       │ • Phase Rules    │
                       │ • Conditions     │
                       │ • Policies       │
                       └──────────────────┘
```

**Data Flow:**
1. **Source**: `GET /v1/clusters/{id}/statuses` - Complete adapter data with all conditions
2. **Processing**: Aggregation engine extracts key fields and applies expr rules
3. **Output**: Aggregated `status` included in `GET /v1/clusters/{id}` response

**Field Mapping:**
```
/statuses                           →    cluster.status
─────────────────────────────────────    ────────────────────────
adapterStatuses[].adapter           →    status.adapters[].name
adapterStatuses[].observedGeneration →    status.adapters[].observedGeneration
adapterStatuses[].conditions[       →    status.adapters[].available
  type="Available"].status

Config YAML                         →    cluster.status
─────────────────────────────────────    ────────────────────────
phases[phaseName].description       →    status.phaseDescription
```

### Rule Evaluation Process

The aggregation engine follows this process:

#### 1. **Data Collection**
```go
// Collect all adapter statuses for cluster
adapterStatuses := getAdapterStatuses(clusterId, generation)
config := getAggregationConfig(clusterType)
```

#### 2. **Phase Evaluation (Hardcoded Priority)**
```go
// Phase evaluation uses hardcoded priority for robustness
func evaluateClusterPhase(adapterStatuses []AdapterStatus, config AggregationConfig) PhaseResult {
    // 1. DEGRADED - Highest priority (health issues must be visible)
    if evaluatePhaseCondition("degraded", adapterStatuses, config) {
        return PhaseResult{
            Name: "Degraded",
            Description: getPhaseDescription(config, "degraded"),
        }
    }

    // 2. FAILED - Business logic failures
    if evaluatePhaseCondition("failed", adapterStatuses, config) {
        return PhaseResult{
            Name: "Failed",
            Description: getPhaseDescription(config, "failed"),
        }
    }

    // 3. READY - All required adapters completed successfully
    if evaluatePhaseCondition("ready", adapterStatuses, config) {
        return PhaseResult{
            Name: "Ready",
            Description: getPhaseDescription(config, "ready"),
        }
    }

    // 4. PROVISIONING - One or more adapters actively working
    if evaluatePhaseCondition("provisioning", adapterStatuses, config) {
        return PhaseResult{
            Name: "Provisioning",
            Description: getPhaseDescription(config, "provisioning"),
        }
    }

    // 5. PENDING - Initial state (fallback)
    return PhaseResult{
        Name: "Pending",
        Description: getPhaseDescription(config, "pending"),
    }
}

func getPhaseDescription(config AggregationConfig, phaseName string) string {
    for _, phase := range config.Phases {
        if phase.Name == phaseName {
            return phase.Description
        }
    }
    return "" // Fallback if not found
}

// evaluatePhaseCondition evaluates all required conditions for a phase using expr
func evaluatePhaseCondition(phaseName string, adapterStatuses []AdapterStatus, config AggregationConfig) bool {
    phase := config.Phases[phaseName]
    for _, conditionRef := range phase.RequiredConditions {
        condition := findCondition(config.ClusterConditions, conditionRef.Type)
        result := evaluateExprCondition(adapterStatuses, config, condition)

        // Check if result matches expected status
        if (conditionRef.Status == "True" && !result) || (conditionRef.Status == "False" && result) {
            return false
        }
    }
    return true
}
```

**Why Hardcoded Priority is More Robust:**
- **Consistent behavior** across all environments and configurations
- **Prevents misconfiguration** that could hide critical states (e.g., degraded)
- **Business logic enforced** - health issues always visible regardless of config
- **Simpler implementation** - no need for complex priority sorting
- **Predictable outcomes** - phase transitions follow fixed, well-understood rules

#### 3. **Condition Generation**
```go
// Generate cluster conditions based on expr evaluation
for _, conditionRule := range config.ClusterConditions {
    condition := evaluateConditionRule(adapterStatuses, config, conditionRule)
    clusterConditions = append(clusterConditions, condition)
}
```

**Condition Reason/Message Generation:**

The YAML config defines **HOW** to evaluate conditions using expr expressions **AND** provides templates for `reason` and `message`:

```go
func evaluateConditionRule(adapterStatuses []AdapterStatus, config AggregationConfig, rule ConditionRule) Condition {
    // Evaluate the expr expression
    result := evaluateExprCondition(adapterStatuses, config, rule)

    // Get template based on evaluation result
    var template ConditionTemplate
    if result {
        template = rule.Templates.True
    } else {
        template = rule.Templates.False
    }

    // Build context data for template rendering
    context := buildTemplateContext(adapterStatuses, rule)

    // Render message template with dynamic data
    message := renderTemplate(template.Message, context)

    return Condition{
        Type:               rule.Type,
        Status:             boolToStatus(result),
        Reason:            template.Reason,        // ← From config template
        Message:           message,               // ← Rendered from template + context
        LastTransitionTime: time.Now(),
    }
}

// evaluateExprCondition evaluates an expr expression
func evaluateExprCondition(adapterStatuses []AdapterStatus, config AggregationConfig, rule ConditionRule) bool {
    // Prepare environment with available data
    env := map[string]interface{}{
        "requiredAdapters":  filterAdapters(adapterStatuses, config.RequiredAdapters),
        "optionalAdapters":  filterAdapters(adapterStatuses, config.OptionalAdapters),
        "allAdapters":       adapterStatuses,
        "adapters":          statusesAsMap(adapterStatuses),
        "currentGeneration": config.CurrentGeneration,
    }

    // Compile and execute expression
    program, err := expr.Compile(rule.Evaluate.Expr, expr.Env(env), expr.AsBool())
    if err != nil {
        // Log error and return false
        log.Error("Failed to compile expression for condition %s: %v", rule.Type, err)
        return false
    }

    result, err := expr.Run(program, env)
    if err != nil {
        // Log error and return false
        log.Error("Failed to execute expression for condition %s: %v", rule.Type, err)
        return false
    }

    return result.(bool)
}

func buildTemplateContext(adapterStatuses []AdapterStatus, rule ConditionRule) map[string]interface{} {
    failedAdapters := getFailedAdapters(adapterStatuses)

    return map[string]interface{}{
        "FailedCount":             len(failedAdapters),
        "TotalCount":              len(getRequiredAdapters()),
        "FailedAdapterNames":      strings.Join(failedAdapters, ", "),
        "UnhealthyAdapterNames":   strings.Join(getUnhealthyAdapters(adapterStatuses), ", "),
        "WorkingCount":            getWorkingAdapterCount(adapterStatuses),
        "AdapterFailureMessage":   getFirstAdapterFailureMessage(adapterStatuses),
        "FirstFailureMessage":     getFirstFailureMessage(adapterStatuses),
    }
}
```

**Template Variables Available:**

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `{{.FailedCount}}` | Number of failed adapters | `"2"` |
| `{{.TotalCount}}` | Total required adapters | `"4"` |
| `{{.FailedAdapterNames}}` | Comma-separated failed adapter names | `"validation, dns"` |
| `{{.UnhealthyAdapterNames}}` | Comma-separated unhealthy adapter names | `"monitoring"` |
| `{{.WorkingCount}}` | Number of actively working adapters | `"2"` |
| `{{.AdapterFailureMessage}}` | Specific failure message from adapter | `"Route53 zone not found for domain example.com"` |
| `{{.FirstFailureMessage}}` | First failure message for debugging | `"Route53 zone not found for domain example.com"` |

**Example Template Rendering:**
```yaml
# Config with expr evaluation
clusterConditions:
  - type: "AllAdaptersReady"
    evaluate:
      expr: 'all(requiredAdapters, {.available == "True"})'
    templates:
      false:
        reason: "RequiredAdaptersNotReady"
        message: "{{.FailedCount}} of {{.TotalCount}} required adapters not ready: {{.FailedAdapterNames}}"

# Step 1: Evaluate expr expression
expr: 'all(requiredAdapters, {.available == "True"})'
# With requiredAdapters = [
#   {adapter: "validation", available: "False"},
#   {adapter: "dns", available: "False"},
#   {adapter: "infrastructure", available: "True"},
#   {adapter: "hypershift", available: "True"}
# ]
# Result: false (not ALL are True)

# Step 2: Build context data for template
{
  "FailedCount": 2,
  "TotalCount": 4,
  "FailedAdapterNames": "validation, dns"
}

# Step 3: Render template with context
{
  "type": "AllAdaptersReady",
  "status": "False",                          # ← From expr result
  "reason": "RequiredAdaptersNotReady",       # ← From template
  "message": "2 of 4 required adapters not ready: validation, dns"  # ← Rendered
}
```

**Benefits of Template-based Approach:**

1. **No source code changes** - Adding new conditions only requires YAML config changes
2. **Consistent messaging** - Templates ensure uniform message formatting
3. **Localization ready** - Easy to swap templates for different languages
4. **Testable** - Template rendering can be unit tested independently
5. **Flexible** - Can customize messages per environment without code changes

**Adding New Conditions - No Code Changes Required:**

To add a new condition like "HyperShiftReady", just add to YAML config:

```yaml
clusterConditions:
  # ... existing conditions ...

  # NEW: Add this to config, no source code changes needed!
  - type: "HyperShiftReady"
    evaluate:
      expr: 'adapters["hypershift"].available == "True"'
    templates:
      true:
        reason: "ClusterDeployed"
        message: "HyperShift cluster deployed and operational"
      false:
        reason: "HyperShiftNotReady"
        message: "{{.AdapterFailureMessage}}"
```

**More Complex Example:**

```yaml
  # NEW: Check HyperShift is ready AND healthy with current generation
  - type: "HyperShiftFullyReady"
    evaluate:
      expr: 'adapters["hypershift"].available == "True" && adapters["hypershift"].health == "True" && adapters["hypershift"].observedGeneration == currentGeneration'
    templates:
      true:
        reason: "ClusterOperational"
        message: "HyperShift cluster is fully operational and up-to-date"
      false:
        reason: "HyperShiftNotFullyReady"
        message: "HyperShift cluster not yet fully operational"
```

**Result:** The aggregation engine automatically:
1. Evaluates the expr expression against current adapter statuses
2. Generates reason/message using the templates
3. Includes it in cluster conditions array

**No Go code changes required!** The power of expr allows you to express any evaluation logic directly in configuration.

#### 4. **Adapter Status Extraction**
```go
// Extract adapter summaries for cluster.status field from detailed /statuses data
func extractAdapterSummaries(detailedStatus ClusterStatus) []AdapterSummary {
    var adapters []AdapterSummary

    for _, adapterStatus := range detailedStatus.AdapterStatuses {
        // Extract the "Available" condition status
        var availableStatus string = "False" // Default fallback
        for _, condition := range adapterStatus.Conditions {
            if condition.Type == "Available" {
                availableStatus = condition.Status  // "True" or "False"
                break
            }
        }

        // Create adapter summary for cluster.status field
        summary := AdapterSummary{
            Name:                adapterStatus.Adapter,        // Direct copy
            Available:           availableStatus,              // Extracted from Available condition
            ObservedGeneration:  adapterStatus.ObservedGeneration, // Direct copy
        }

        adapters = append(adapters, summary)
    }

    return adapters
}
```

**Field Extraction Rules:**
- **`name`** - Direct copy from `adapterStatus.adapter`
- **`available`** - Extracted from `conditions[type="Available"].status`
- **`observedGeneration`** - Direct copy from `adapterStatus.observedGeneration`

**Purpose:** The `cluster.status` field provides a **lightweight projection** of the detailed `/statuses` data, extracting only the essential fields needed for:
- Quick phase calculation
- High-level status overview
- Polling and dashboard displays

**Performance Benefits:**
- Avoids parsing full condition arrays for basic status checks
- Enables fast aggregation logic without condition iteration
- Reduces payload size by including only essential adapter summary

**Example Extraction:**
```json
// Source: GET /statuses + Config YAML
{
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [
        {"type": "Available", "status": "True", "reason": "JobSucceeded"},
        {"type": "Applied", "status": "True", "reason": "JobLaunched"},
        {"type": "Health", "status": "True", "reason": "NoErrors"}
      ]
    }
  ]
}

// Config phases.ready.description
phases:
  ready:
    description: "All required adapters completed successfully"

// Result: cluster.status field in GET /clusters/{id}
{
  "phase": "Ready",                   // ← Calculated from adapter statuses using expr
  "phaseDescription": "All required adapters completed successfully", // ← From config
  "adapters": [
    {
      "name": "validation",           // ← adapter
      "available": "True",            // ← conditions[Available].status
      "observedGeneration": 1         // ← observedGeneration
    }
  ]
}
```

### Expression Evaluation with expr-lang

#### Using expr Expressions

HyperFleet uses **[expr-lang/expr](https://expr-lang.org/)** to evaluate conditions. Expr is a powerful, safe expression language with the following guarantees:

- **Memory-safe**: No access to unrelated memory
- **Side-effect-free**: Expressions only compute outputs from inputs (no I/O, network calls)
- **Always terminating**: No infinite loops
- **Type-safe**: Compile-time type checking

#### Available Variables in Expressions

When evaluating expressions, the following variables are available:

| Variable | Type | Description |
|----------|------|-------------|
| `requiredAdapters` | `[]AdapterStatus` | Array of required adapter statuses |
| `optionalAdapters` | `[]AdapterStatus` | Array of optional adapter statuses |
| `allAdapters` | `[]AdapterStatus` | Array of all adapter statuses |
| `adapters` | `map[string]AdapterStatus` | Map of adapter name → status |
| `currentGeneration` | `int` | Current cluster generation |

#### AdapterStatus Fields

Each adapter status object has the following fields accessible in expressions:

```go
type AdapterStatus struct {
    Adapter            string  // Adapter name (e.g., "validation")
    Available          string  // "True" or "False"
    Applied            string  // "True" or "False"
    Health             string  // "True" or "False"
    ObservedGeneration int     // Generation this adapter reconciled
    LastUpdated        time.Time
}
```

#### Common Expression Patterns

**Check all required adapters are ready:**
```yaml
expr: 'all(requiredAdapters, {.available == "True"})'
```

**Check if any adapter is unhealthy:**
```yaml
expr: 'any(allAdapters, {.health == "False"})'
```

**Check specific adapter status:**
```yaml
expr: 'adapters["validation"].available == "True"'
```

**Check multiple conditions:**
```yaml
expr: 'all(requiredAdapters, {.available == "True" && .health == "True"})'
```

**Check with generation:**
```yaml
expr: 'all(requiredAdapters, {.observedGeneration == currentGeneration})'
```

**Complex logic:**
```yaml
# At least 3 adapters ready
expr: 'len(filter(requiredAdapters, {.available == "True"})) >= 3'

# Validation ready OR all optional adapters ready
expr: 'adapters["validation"].available == "True" || all(optionalAdapters, {.available == "True"})'

# Check for adapters that are applied but not yet available (provisioning)
expr: 'any(allAdapters, {.applied == "True" && .available == "False"})'
```

#### expr Built-in Functions

Commonly used expr functions:

- **all(array, predicate)** - Returns true if all elements satisfy predicate
- **any(array, predicate)** - Returns true if any element satisfies predicate
- **filter(array, predicate)** - Returns filtered array
- **len(array)** - Returns array length
- **map(array, predicate)** - Returns transformed array

For complete expr documentation, see https://expr-lang.org/docs/language-definition

### Generation Handling

The aggregation engine respects generation constraints to prevent stale data issues. You can check generation in your expressions:

```yaml
# Only count adapters that have reconciled current generation
clusterConditions:
  - type: "AllAdaptersReporting"
    evaluate:
      expr: 'all(requiredAdapters, {.observedGeneration == currentGeneration})'

# Check if adapter is current AND ready
  - type: "ValidationPassed"
    evaluate:
      expr: 'adapters["validation"].observedGeneration == currentGeneration && adapters["validation"].available == "True"'
```

**Common Generation Checks**:
- `{.observedGeneration == currentGeneration}` - Adapter has reconciled current generation
- `{.observedGeneration < currentGeneration}` - Adapter is behind (stale)
- `{.observedGeneration > currentGeneration}` - Should not happen (error condition)

### Configuration Validation

To ensure configuration correctness, validate all expr expressions during startup or in CI/CD:

```go
// Validate all expressions in configuration
func ValidateAggregationConfig(config AggregationConfig) error {
    // Mock environment for validation
    mockEnv := map[string]interface{}{
        "requiredAdapters":  []AdapterStatus{},
        "optionalAdapters":  []AdapterStatus{},
        "allAdapters":       []AdapterStatus{},
        "adapters":          map[string]AdapterStatus{},
        "currentGeneration": 1,
    }

    for _, condition := range config.ClusterConditions {
        // Compile expression with type checking
        _, err := expr.Compile(
            condition.Evaluate.Expr,
            expr.Env(mockEnv),
            expr.AsBool(), // Ensure expression returns boolean
        )
        if err != nil {
            return fmt.Errorf("invalid expression for condition %s: %w", condition.Type, err)
        }
    }

    return nil
}
```

**CI/CD Integration:**

```go
// tests/config_validation_test.go
func TestAggregationConfigExpressions(t *testing.T) {
    config := loadAggregationConfig("../config/aggregation.yaml")

    err := ValidateAggregationConfig(config)
    require.NoError(t, err, "Configuration contains invalid expressions")
}
```

### Expression Debugging

When an expression evaluates unexpectedly, use logging to debug:

```go
func evaluateExprCondition(adapterStatuses []AdapterStatus, config AggregationConfig, rule ConditionRule) bool {
    env := prepareEnvironment(adapterStatuses, config)

    program, err := expr.Compile(rule.Evaluate.Expr, expr.Env(env), expr.AsBool())
    if err != nil {
        log.Error("Compile error for condition %s: %v", rule.Type, err)
        log.Error("Expression: %s", rule.Evaluate.Expr)
        return false
    }

    result, err := expr.Run(program, env)
    if err != nil {
        log.Error("Runtime error for condition %s: %v", rule.Type, err)
        log.Error("Expression: %s", rule.Evaluate.Expr)
        log.Debug("Environment: %+v", env)
        return false
    }

    boolResult := result.(bool)

    // Debug logging when condition is false
    if !boolResult {
        log.Debug("Condition %s evaluated to false", rule.Type)
        log.Debug("Expression: %s", rule.Evaluate.Expr)
        log.Debug("Required adapters: %+v", env["requiredAdapters"])
    }

    return boolResult
}
```

**Common Expression Errors:**

| Error | Cause | Solution |
|-------|-------|----------|
| `unknown name "foo"` | Variable not in environment | Check available variables list |
| `invalid operation: string + int` | Type mismatch | Ensure types match in comparisons |
| `cannot use [] on type string` | Invalid array access | Verify variable is array/map |
| `expected bool, got string` | Expression doesn't return boolean | Add comparison (e.g., `== "True"`) |

### Advanced Expression Examples

**Percentage-based checks:**
```yaml
# At least 75% of adapters ready
clusterConditions:
  - type: "MajorityAdaptersReady"
    evaluate:
      expr: 'len(filter(requiredAdapters, {.available == "True"})) >= len(requiredAdapters) * 0.75'
```

**Fallback logic:**
```yaml
# Primary adapter OR backup adapter ready
clusterConditions:
  - type: "ValidationPathReady"
    evaluate:
      expr: 'adapters["validation"].available == "True" || adapters["validation-backup"].available == "True"'
```

**Multi-step validation:**
```yaml
# Validation AND (DNS OR Infrastructure) ready
clusterConditions:
  - type: "CoreProvisioning"
    evaluate:
      expr: 'adapters["validation"].available == "True" && (adapters["dns"].available == "True" || adapters["infrastructure"].available == "True")'
```

**Stale adapter detection:**
```yaml
# Check if any adapter hasn't updated in 10 minutes
clusterConditions:
  - type: "NoStaleAdapters"
    evaluate:
      # Note: This would require adding duration helpers to environment
      expr: 'all(allAdapters, {.observedGeneration == currentGeneration})'
```

**Counting specific states:**
```yaml
# Exactly 2 adapters in provisioning state
clusterConditions:
  - type: "TwoAdaptersProvisioning"
    evaluate:
      expr: 'len(filter(allAdapters, {.applied == "True" && .available == "False"})) == 2'
```

### Error Handling and Fallbacks

The aggregation engine handles various error scenarios:

#### Missing Adapter Status
```yaml
# When required adapter hasn't reported yet
defaultBehavior:
  missingAdapter: "pending"    # Default to pending phase
  timeout: "10m"              # Wait timeout before marking failed
```

#### Stale Status Detection
```yaml
policies:
  staleThreshold: "10m"        # Consider status stale after 10 minutes
  staleAction: "degraded"      # Move to degraded if stale
```


---

## Complete Status Lifecycle Examples

The following examples show **individual adapter status payloads** that adapters send. These become entries in the ClusterStatus `adapterStatuses` array.

### 1. Adapter Started (Job Created)

**Scenario**: Validation adapter received event, created Job. This is the first adapter to report, so it POSTs to create the ClusterStatus.

**POST** `/v1/clusters/cls-123/statuses`

```json
{
  "generation": 1,
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "JobRunning",
          "message": "Validation Job is executing",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job 'validation-cls-123-gen1' created successfully",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "Adapter is healthy",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        }
      ],
      "metadata": {
        "jobName": "validation-cls-123-gen1",
        "jobNamespace": "hyperfleet-jobs"
      },
      "lastUpdated": "2025-10-17T12:00:05Z"
    }
  ]
}
```

**What This Means**:
- Job created successfully (Applied: True)
- Job is running (Available: False - not yet complete)
- No errors (Health: True)

---

### 2. Adapter Succeeded

**Scenario**: Validation Job completed successfully. ClusterStatus now exists, so validation adapter PATCHes to update its status.

**PATCH** `/v1/clusters/cls-123/statuses/{statusId}`

```json
{
  "adapter": "validation",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "True",
      "reason": "JobSucceeded",
      "message": "Job completed successfully after 115 seconds",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPassed",
      "message": "All validation checks passed",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": true,
      "s3BucketAccessible": true,
      "quotaSufficient": true,
      "iamPermissionsValid": true
    },
    "checksPerformed": 15,
    "checksPassed": 15,
    "executionTime": "115s"
  },
  "metadata": {
    "jobName": "validation-cls-123-gen1",
    "completedAt": "2025-10-17T12:02:00Z"
  },
  "lastUpdated": "2025-10-17T12:02:00Z"
}
```

**What This Means**:
- Job created (Applied: True)
- Job succeeded (Available: True)
- No errors (Health: True)
- Detailed results in `data` field

**Next Steps**: DNS adapter can now proceed (validation complete)

---

### 3. Adapter Failed (Business Logic)

**Scenario**: Validation Job ran but found missing Route53 zone

**PATCH** `/v1/clusters/cls-123/statuses/{statusId}`

```json
{
  "adapter": "validation",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ValidationFailed",
      "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster.",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "Applied",
      "status": "True",
      "reason": "JobLaunched",
      "message": "Kubernetes Job created successfully",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter executed normally (validation logic failed, not adapter error)",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    }
  ],
  "data": {
    "validationResults": {
      "route53ZoneFound": false,
      "s3BucketAccessible": true,
      "quotaSufficient": true
    },
    "checksPerformed": 15,
    "checksPassed": 14,
    "checksFailed": 1,
    "failedChecks": ["route53_zone"]
  },
  "lastUpdated": "2025-10-17T12:02:00Z"
}
```

**What This Means**:
- Job created (Applied: True)
- Validation failed (Available: False)
- Adapter is healthy (Health: True) - **validation failure is expected behavior**

**Key Point**: `Health: True` because the adapter worked correctly. The validation *logic* failed (missing DNS zone), but the adapter itself had no errors.

---

### 4. Adapter Failed (Unexpected Error)

**Scenario**: Adapter couldn't create Job due to quota exceeded. If ClusterStatus doesn't exist yet, this could be a POST. If it exists, PATCH.

**PATCH** `/v1/clusters/cls-123/statuses/{statusId}`

```json
{
  "adapter": "validation",
  "observedGeneration": 1,
  "conditions": [
    {
      "type": "Available",
      "status": "False",
      "reason": "ResourceCreationFailed",
      "message": "Failed to create validation Job",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Applied",
      "status": "False",
      "reason": "ResourceQuotaExceeded",
      "message": "Failed to create Job: namespace resource quota exceeded (cpu limit reached)",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "Health",
      "status": "False",
      "reason": "UnexpectedError",
      "message": "Adapter could not complete due to resource quota limits",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    }
  ],
  "data": {
    "error": {
      "type": "ResourceQuotaExceeded",
      "message": "CPU limit reached",
      "namespace": "hyperfleet-jobs"
    }
  },
  "lastUpdated": "2025-10-17T12:00:05Z"
}
```

**What This Means**:
- Job NOT created (Applied: False)
- Work incomplete (Available: False)
- Adapter unhealthy (Health: False) - **unexpected error prevented normal operation**

**Key Point**: `Health: False` because this is an unexpected infrastructure issue, not expected business logic.

---

### Complete ClusterStatus Example

Here's what a complete ClusterStatus object looks like with multiple adapters at different stages:

**GET** `/v1/clusters/cls-550e8400/statuses?generation=1`

```json
{
  "id": "status-cls-550e8400-gen1",
  "type": "clusterStatus",
  "href": "/api/hyperfleet/v1/clusters/cls-550e8400/statuses/status-cls-550e8400-gen1",
  "clusterId": "cls-550e8400",
  "generation": 1,
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "True",
          "reason": "JobSucceeded",
          "message": "Job completed successfully after 115 seconds",
          "lastTransitionTime": "2025-10-17T12:02:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "Kubernetes Job created successfully",
          "lastTransitionTime": "2025-10-17T12:00:05Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "AllChecksPassed",
          "message": "All validation checks passed",
          "lastTransitionTime": "2025-10-17T12:02:00Z"
        }
      ],
      "data": {
        "validationResults": {
          "route53ZoneFound": true,
          "s3BucketAccessible": true,
          "quotaSufficient": true
        }
      },
      "metadata": {
        "jobName": "validation-cls-123-gen1"
      },
      "lastUpdated": "2025-10-17T12:02:00Z"
    },
    {
      "adapter": "dns",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "JobRunning",
          "message": "DNS Job is executing",
          "lastTransitionTime": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Applied",
          "status": "True",
          "reason": "JobLaunched",
          "message": "DNS Job created successfully",
          "lastTransitionTime": "2025-10-17T12:03:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "DNS adapter is healthy",
          "lastTransitionTime": "2025-10-17T12:03:00Z"
        }
      ],
      "metadata": {
        "jobName": "dns-cls-123-gen1"
      },
      "lastUpdated": "2025-10-17T12:03:00Z"
    },
    {
      "adapter": "infrastructure",
      "observedGeneration": 1,
      "conditions": [
        {
          "type": "Available",
          "status": "False",
          "reason": "NotStarted",
          "message": "Waiting for dns to complete",
          "lastTransitionTime": "2025-10-17T12:00:00Z"
        },
        {
          "type": "Applied",
          "status": "False",
          "reason": "PreconditionsNotMet",
          "message": "Waiting for dns adapter",
          "lastTransitionTime": "2025-10-17T12:00:00Z"
        },
        {
          "type": "Health",
          "status": "True",
          "reason": "NoErrors",
          "message": "Adapter is healthy",
          "lastTransitionTime": "2025-10-17T12:00:00Z"
        }
      ],
      "lastUpdated": "2025-10-17T12:00:00Z"
    }
  ],
  "lastUpdated": "2025-10-17T12:03:00Z"
}
```

**What This Shows**:
- **validation**: Completed successfully
- **dns**: Currently running
- **infrastructure**: Waiting for preconditions (dns completion)
- All adapter statuses in ONE cohesive ClusterStatus object
- Easy to fetch and display complete cluster provisioning status

---

## Complete Cluster Scenarios with Phase Transitions

This section demonstrates how cluster phases and conditions evolve throughout the complete lifecycle, showing the interplay between adapter statuses and cluster aggregation.

### Scenario 1: Successful Cluster Provisioning

#### Stage 1: Initial State (Pending)

**Cluster State**: Just created, no adapters have started yet.

**GET** `/v1/clusters/cls-123`

```json
{
  "phase": "Pending",
  "phaseDescription": "Waiting for adapters to start processing",
  "conditions": [
    {
      "type": "AllAdaptersReporting",
      "status": "False",
      "reason": "AdaptersNotStarted",
      "message": "Waiting for adapters to begin processing cluster request",
      "lastTransitionTime": "2025-10-17T12:00:00Z"
    }
  ],
  "adapters": [],
  "lastUpdated": "2025-10-17T12:00:00Z"
}
```

#### Stage 2: Validation Started (Provisioning)

**Cluster State**: Validation adapter started working.

**GET** `/v1/clusters/cls-123` (status field)

```json
{
  "phase": "Provisioning",
  "conditions": [
    {
      "type": "ProvisioningInProgress",
      "status": "True",
      "reason": "AdaptersWorking",
      "message": "1 of 4 adapters actively provisioning resources",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    },
    {
      "type": "ValidationPassed",
      "status": "False",
      "reason": "ValidationInProgress",
      "message": "Validation adapter is currently running checks",
      "lastTransitionTime": "2025-10-17T12:00:05Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "False",
      "observedGeneration": 1
    }
  ],
  "lastUpdated": "2025-10-17T12:00:05Z"
}
```

#### Stage 3: Validation Complete, DNS Started (Provisioning)

**Cluster State**: Validation succeeded, DNS adapter now working.

**GET** `/v1/clusters/cls-123` (status field)

```json
{
  "phase": "Provisioning",
  "conditions": [
    {
      "type": "ProvisioningInProgress",
      "status": "True",
      "reason": "AdaptersWorking",
      "message": "1 of 4 adapters actively provisioning resources",
      "lastTransitionTime": "2025-10-17T12:03:00Z"
    },
    {
      "type": "ValidationPassed",
      "status": "True",
      "reason": "AllValidationChecksPassed",
      "message": "Validation adapter completed all checks successfully",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "DNSConfigured",
      "status": "False",
      "reason": "DNSProvisioningInProgress",
      "message": "DNS adapter is creating Route53 records",
      "lastTransitionTime": "2025-10-17T12:03:00Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "dns",
      "available": "False",
      "observedGeneration": 1
    }
  ],
  "lastUpdated": "2025-10-17T12:03:00Z"
}
```

#### Stage 4: All Adapters Complete (Ready)

**Cluster State**: All required adapters completed successfully.

**GET** `/v1/clusters/cls-123` (status field)

```json
{
  "phase": "Ready",
  "phaseDescription": "All required adapters completed successfully",
  "conditions": [
    {
      "type": "AllAdaptersReady",
      "status": "True",
      "reason": "AllRequiredAdaptersAvailable",
      "message": "All required adapters completed successfully",
      "lastTransitionTime": "2025-10-17T12:15:00Z"
    },
    {
      "type": "ValidationPassed",
      "status": "True",
      "reason": "AllValidationChecksPassed",
      "message": "Validation adapter completed all checks successfully",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "DNSConfigured",
      "status": "True",
      "reason": "AllRecordsCreated",
      "message": "DNS adapter created all required records",
      "lastTransitionTime": "2025-10-17T12:05:00Z"
    },
    {
      "type": "InfrastructureReady",
      "status": "True",
      "reason": "AllResourcesProvisioned",
      "message": "Infrastructure adapter provisioned all required resources",
      "lastTransitionTime": "2025-10-17T12:10:00Z"
    },
    {
      "type": "HyperShiftReady",
      "status": "True",
      "reason": "ClusterDeployed",
      "message": "HyperShift cluster deployed and operational",
      "lastTransitionTime": "2025-10-17T12:15:00Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "dns",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "infrastructure",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "hypershift",
      "available": "True",
      "observedGeneration": 1
    }
  ],
  "lastUpdated": "2025-10-17T12:15:00Z"
}
```

### Scenario 2: Cluster Provisioning with Failure

#### Stage 1: Validation Failure (Failed)

**Cluster State**: Validation adapter failed due to missing DNS zone.

**GET** `/v1/clusters/cls-456` (status field)

```json
{
  "phase": "Failed",
  "conditions": [
    {
      "type": "AdaptersFailed",
      "status": "True",
      "reason": "RequiredAdapterFailure",
      "message": "Validation failed: Route53 zone not found for domain example.com",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "ValidationPassed",
      "status": "False",
      "reason": "ValidationFailed",
      "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster.",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "False",
      "observedGeneration": 1
    }
  ],
  "lastUpdated": "2025-10-17T12:02:00Z"
}
```

#### Stage 2: After Manual Fix - Retry (Provisioning)

**Cluster State**: User created DNS zone, cluster spec updated to generation 2, validation restarted.

**GET** `/v1/clusters/cls-456` (status field)

```json
{
  "phase": "Provisioning",
  "conditions": [
    {
      "type": "ProvisioningInProgress",
      "status": "True",
      "reason": "AdaptersWorking",
      "message": "1 of 4 adapters actively provisioning resources",
      "lastTransitionTime": "2025-10-17T13:00:05Z"
    },
    {
      "type": "ValidationPassed",
      "status": "False",
      "reason": "ValidationInProgress",
      "message": "Validation adapter is currently running checks",
      "lastTransitionTime": "2025-10-17T13:00:05Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "False",
      "observedGeneration": 2
    }
  ],
  "lastUpdated": "2025-10-17T13:00:05Z"
}
```

### Scenario 3: Cluster with Health Issues (Degraded)

#### Stage 1: Operational but Unhealthy (Degraded)

**Cluster State**: All adapters completed but monitoring adapter has health issues.

**GET** `/v1/clusters/cls-789` (status field)

```json
{
  "phase": "Degraded",
  "conditions": [
    {
      "type": "AdaptersUnhealthy",
      "status": "True",
      "reason": "HealthCheckFailures",
      "message": "Monitoring adapter experiencing API connection failures",
      "lastTransitionTime": "2025-10-17T12:20:00Z"
    },
    {
      "type": "AllAdaptersReady",
      "status": "True",
      "reason": "AllRequiredAdaptersAvailable",
      "message": "All required adapters completed successfully",
      "lastTransitionTime": "2025-10-17T12:15:00Z"
    },
    {
      "type": "ValidationPassed",
      "status": "True",
      "reason": "AllValidationChecksPassed",
      "message": "Validation adapter completed successfully",
      "lastTransitionTime": "2025-10-17T12:02:00Z"
    },
    {
      "type": "MonitoringConfigured",
      "status": "False",
      "reason": "HealthCheckFailures",
      "message": "Monitoring adapter experiencing connectivity issues",
      "lastTransitionTime": "2025-10-17T12:20:00Z"
    }
  ],
  "adapters": [
    {
      "name": "validation",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "dns",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "infrastructure",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "hypershift",
      "available": "True",
      "observedGeneration": 1
    },
    {
      "name": "monitoring",
      "available": "True",
      "observedGeneration": 1
    }
  ],
  "lastUpdated": "2025-10-17T12:20:00Z"
}
```

### Condition Generation Examples

These examples show how specific cluster conditions are generated based on adapter statuses:

#### AllAdaptersReady Condition
```yaml
# Generated when all required adapters have Available: True
{
  "type": "AllAdaptersReady",
  "status": "True",
  "reason": "AllRequiredAdaptersAvailable",
  "message": "All required adapters (validation, dns, infrastructure, hypershift) completed successfully",
  "lastTransitionTime": "2025-10-17T12:15:00Z"
}
```

#### ValidationPassed Condition
```yaml
# Generated based on validation adapter status
{
  "type": "ValidationPassed",
  "status": "True",
  "reason": "AllValidationChecksPassed",
  "message": "Validation adapter completed all checks successfully",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}
```

#### ProvisioningInProgress Condition
```yaml
# Generated when adapters are actively working
{
  "type": "ProvisioningInProgress",
  "status": "True",
  "reason": "AdaptersWorking",
  "message": "2 of 4 adapters actively provisioning resources",
  "lastTransitionTime": "2025-10-17T12:03:00Z"
}
```

---

## Common Status Query Patterns

### 1. Wait for Specific Adapter

To poll until an adapter completes:
1. Fetch the cluster repeatedly (e.g., every 5 seconds): `GET /v1/clusters/{clusterId}`
2. Find the adapter in `status.adapters` array
3. Check if adapter exists (has reported at least once)
4. Verify `observedGeneration === cluster.generation` (not stale)
5. Check `available` field:
   - `"True"` → adapter succeeded, stop polling
   - `"False"` → adapter failed or in progress
6. If `"False"`, fetch detailed status to check reason:
   - `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
   - Find the adapter in `adapterStatuses` array
   - Check `Available` condition's `reason`:
     - `JobRunning` or `JobPending` → still in progress, continue polling
     - Other reasons → adapter actually failed, stop polling
7. Implement timeout (e.g., 10 minutes)

### 2. Check If Cluster is Ready

To verify cluster is fully provisioned:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Check `status.phase === "Ready"`
3. Optionally verify each adapter in `status.adapters`:
   - All have `observedGeneration === cluster.generation`
   - All have `available === "True"`

### 3. Get Failed Adapters

To identify which adapters have failed:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. Iterate through `status.adapters`
3. For each adapter:
   - If `observedGeneration < cluster.generation` → stale, skip
   - If `available === "False"`, collect adapter name
4. Fetch detailed status for all adapters:
   - `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
5. For each failed adapter (from step 3), find it in `adapterStatuses` array:
   - Get `Available` condition's `message` and `reason`
   - Get `Health` condition to determine if it's a health issue
6. Return list with failure details

### 4. Display Adapter Progress

To show progress UI:
1. Fetch cluster: `GET /v1/clusters/{clusterId}`
2. For each adapter in `status.adapters`:
   - `available: "True"` → Completed
   - `available: "False"` → Need to check details
3. Fetch detailed status: `GET /v1/clusters/{clusterId}/statuses?generation={generation}`
4. For adapters with `available: "False"`:
   - Find adapter in `adapterStatuses` array
   - Check conditions:
     - `Health: False` → Unhealthy
     - `Available: False` with `JobRunning` reason → Running
     - `Available: False` with failure reason → Failed
     - `Applied: False` → Pending
5. Display adapter name, status icon, generation, and message from conditions

**Example Output**:
```
validation - completed (gen 1)
   Job completed successfully after 115 seconds
dns - completed (gen 1)
   Created 5 DNS records
infrastructure - running (gen 1)
   Kubernetes Job created successfully
hypershift - pending (gen 0)
   Not started
```

---

## Condition Reference

### Required Conditions (All Adapters)

| Type | True | False |
|------|------|-------|
| `Available` | Work completed successfully | Work failed, incomplete, or still in progress |
| `Applied` | Resources created successfully | Failed to create resources or not yet attempted |
| `Health` | No unexpected errors | Unexpected error occurred |

### Common Reason Values

**Available**:
- `JobSucceeded` - Job completed successfully
- `JobFailed` - Job failed
- `JobRunning` - Job still executing
- `ValidationPassed` - Validation checks passed
- `ValidationFailed` - Validation checks failed

**Applied**:
- `JobLaunched` - Job created successfully
- `ResourceCreationFailed` - Failed to create resource
- `ResourceQuotaExceeded` - Quota limit reached

**Health**:
- `NoErrors` - Adapter is healthy
- `AllChecksPassed` - All health checks passed
- `UnexpectedError` - Unexpected error occurred
- `ResourceNotFound` - Expected resource not found
- `APIConnectionFailed` - Failed to connect to API

---

## Best Practices

### DO

1. **Always include all three required conditions**
   ```json
   {
     "conditions": [
       {"type": "Available", "status": "True", /* ... */},
       {"type": "Applied", "status": "True", /* ... */},
       {"type": "Health", "status": "True", /* ... */}
     ]
   }
   ```

2. **Use positive condition types**
   - `DNSRecordsCreated` (status: True/False)
   - `DNSRecordsFailed` (confusing)

3. **Aggregate conditions to determine Available**
   - If any sub-condition is `False`, set `Available` to `False`
   - If all sub-conditions are `True`, set `Available` to `True`

4. **Provide actionable messages**
   ```json
   {
     "message": "Route53 zone not found for domain example.com. Create a public hosted zone before provisioning cluster."
   }
   ```

5. **Use data field for structured information**
   ```json
   {
     "data": {
       "validationResults": { /* detailed results */ }
     }
   }
   ```

### DON'T

1. **Don't omit required conditions**
   ```json
   // BAD: Missing Health condition
   {
     "conditions": [
       {"type": "Available", /* ... */},
       {"type": "Applied", /* ... */}
     ]
   }
   ```

2. **Don't use negative condition names**
   ```json
   // BAD
   {"type": "ValidationFailed", "status": "True"}

   // GOOD
   {"type": "ValidationComplete", "status": "False"}
   ```

3. **Don't set Health: False for business logic failures**
   ```json
   // BAD: Validation failure is expected behavior
   {
     "type": "Health",
     "status": "False",
     "reason": "ValidationFailed"
   }

   // GOOD: Health is about adapter health, not business logic
   {
     "type": "Health",
     "status": "True",
     "reason": "NoErrors"
   }
   ```

---

## Summary

### Architecture Overview

**ClusterStatus Object** (detailed, verbose):
- ONE ClusterStatus per cluster/generation containing all adapter statuses
- Adapters use **upsert pattern**: GET → POST (if 404) or PATCH (if exists)
- POST creates: `POST /v1/clusters/{clusterId}/statuses`
- PATCH updates: `PATCH /v1/clusters/{clusterId}/statuses/{statusId}`
- Contains `adapterStatuses` array with full conditions, data, and metadata for each adapter
- Retrieved via `GET /v1/clusters/{clusterId}/statuses?generation={gen}`
- **RESTful design**: Single resource represents complete cluster status

**Cluster Object** (complete resource):
- Contains `id`, `name`, `generation`, `spec`, and `metadata`
- Contains `status` field with aggregated status:
  - `phase`: "Pending", "Provisioning", "Ready", "Failed", or "Degraded"
  - `phaseDescription`: Human-readable description from configuration
  - `conditions`: Array of cluster-level conditions (AllAdaptersReady, etc.)
  - `adapters`: Array of `{name, available, observedGeneration}`
- Phase calculated by aggregating all adapter `available` conditions using hardcoded priority and expr evaluation
- Retrieved via `GET /v1/clusters/{clusterId}`

### The Contract

1. **Three required conditions**: Available, Applied, Health (in each adapter status)
2. **Single ClusterStatus object**: All adapter statuses grouped in `adapterStatuses` array
3. **Optional data field**: JSONB for structured information per adapter
4. **Additional conditions allowed**: All must be positive assertions
5. **Adapter aggregates**: All condition statuses determine Available
6. **Cluster aggregates**: All adapter Available conditions determine phase

### Condition Meanings

- **Available**: Did the work succeed? (True = complete, False = failed/incomplete/in-progress)
- **Applied**: Were resources created? (True = created, False = failed/not-attempted)
- **Health**: Any unexpected errors? (True = healthy, False = unexpected error)

### Key Principles

1. **Two-tier status model** - Aggregated status in cluster object for quick access, detailed adapter statuses in ClusterStatus resource
2. **RESTful design** - ONE ClusterStatus object per cluster with all adapter statuses
3. **expr-based evaluation** - Flexible condition evaluation using expr-lang without code changes
4. **Conditions are the contract** - Required by API (Available, Applied, Health)
5. **Positive assertions** - All condition types should be positive
6. **Aggregation logic** - Available reflects all sub-conditions
7. **Hardcoded phase priority** - Phase evaluation uses fixed business logic, not configurable rules
8. **Health vs Business Logic** - Health is about adapter errors, not validation failures
9. **Structured data** - Use `data` field for details beyond conditions
10. **Five phases** - Pending → Provisioning → Ready/Failed/Degraded

---
