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

## Cluster Object with Aggregated Status

When you GET a cluster, it contains **aggregated status** from all adapters. The detailed ClusterStatus objects exist separately.

### Cluster Object Structure (MVP)

```json
{
  "id": "cls-550e8400",
  "name": "my-cluster",
  "generation": 1,
  "spec": { /* cluster spec */ },
  "status": {
    "phase": "Ready",
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
      }
    ],
    "lastUpdated": "2025-10-17T12:05:00Z"
  }
}
```

### Status Phase (MVP)

The `phase` field is calculated by aggregating all adapter `available` conditions:

- **`Ready`** - All required adapters have `available: "True"` for current generation
- **`Not Ready`** - One or more adapters have `available: "False"` or haven't reported yet

**Phase Calculation**:
1. Get list of required adapters (e.g., `["validation", "dns", "infrastructure"]`)
2. For each adapter:
   - Check if `observedGeneration === cluster.generation`
   - Check if `available === "True"`
3. If all adapters are `True` and current → `phase: "Ready"`
4. Otherwise → `phase: "Not Ready"`

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

**Cluster Object** (aggregated, lightweight):
- Contains `status.phase`: "Ready" or "Not Ready" (MVP)
- Contains `status.adapters`: Array of `{name, available, observedGeneration}`
- Phase calculated by aggregating all adapter `available` conditions
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

1. **RESTful design** - ONE ClusterStatus object per cluster with all adapter statuses
2. **Separation of concerns** - Detailed status separate from cluster object
3. **Conditions are the contract** - Required by API (Available, Applied, Health)
4. **Positive assertions** - All condition types should be positive
5. **Aggregation logic** - Available reflects all sub-conditions
6. **Health vs Business Logic** - Health is about adapter errors, not validation failures
7. **Structured data** - Use `data` field for details beyond conditions
8. **MVP simplicity** - Phase is binary: Ready or Not Ready

---
