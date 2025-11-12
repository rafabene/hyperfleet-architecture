# HyperFleet Adapter Status Contract

## Overview

This document defines the contract between HyperFleet adapters and the HyperFleet API for status reporting. Adapters use this contract to report their progress, state, and outcomes when processing cluster events.

**Related Documentation:**
- [Adapter Framework Design](./adapter-frame-design.md) - Framework architecture and workflow
- [Adapter Config Template](./adapter-config-template.yaml) - Configuration structure
- [Status Guide](../../docs/status-guide.md) - Comprehensive status guide

---

## API Endpoints

### Status Reporting Endpoint

**Base URL**: `{hyperfleetApiBaseUrl}/api/{hyperfleetApiVersion}/clusters/{clusterId}/statuses`

**Method**:
- `POST` - Upsert ClusterStatus (create or update)

### Upsert Pattern

Adapters **always use POST** for status reporting:

**API Behavior**:
- The HyperFleet API handles the upsert logic server-side
- If ClusterStatus doesn't exist: API creates it
- If ClusterStatus exists: API updates the adapter's status within it
- Idempotent: Same POST multiple times = same result

**Adapter Implementation**:
- No need to GET first to check if status exists
- Always POST to the same endpoint
- API handles create-or-update logic automatically
- Simpler adapter code, fewer HTTP requests

---

## Status Payload Structure

### POST Request (Upsert ClusterStatus)

Always POST the adapter status in this structure:

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
      "data": {
        "validationResults": {
          "route53ZoneFound": true,
          "s3BucketAccessible": true
        }
      },
      "metadata": {
        "jobName": "validation-cls-123-gen1"
      },
      "lastUpdated": "2025-10-17T12:00:05Z"
    }
  ]
}
```

**Notes**:
- The API will merge this adapter status into the existing ClusterStatus if it exists
- If no ClusterStatus exists, the API will create one with this adapter status
- Other adapter statuses in the ClusterStatus are preserved (not affected by this POST)

---

## Required Fields

### Adapter Status Object

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `adapter` | **YES** | string | Adapter name (e.g., "validation", "dns", "placement") |
| `observedGeneration` | **YES** | integer | Cluster generation this adapter has reconciled |
| `conditions` | **YES** | array | **Minimum 3 conditions** (Available, Applied, Health) |
| `data` | NO | object | Adapter-specific structured data (optional) |
| `metadata` | NO | object | Additional metadata (optional) |
| `lastUpdated` | **YES** | timestamp | When this adapter status was last updated (RFC3339) |

### Condition Object

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `type` | **YES** | string | Condition type: "Available", "Applied", or "Health" |
| `status` | **YES** | string | "True" or "False" |
| `reason` | **YES** | string | Short reason code (e.g., "JobSucceeded", "PreconditionsNotMet") |
| `message` | **YES** | string | Human-readable message |
| `lastTransitionTime` | **YES** | timestamp | When condition last transitioned (RFC3339) |

---

## Required Conditions

Every adapter status update **MUST** include these three conditions:

### 1. Applied

**Purpose**: Have resources been successfully applied to Kubernetes?

**Meaning**:
- `True` - Resources exist and are applied (created or already existed)
- `False` - Resources not applied (preconditions not met, or resources don't exist)

**Status Values**:
- `True` - Resources are applied
- `False` - Resources are not applied

**Common Reasons**:
- `ResourcesCreated` - Resources were created successfully
- `ResourcesExist` - Resources already exist
- `PreconditionsNotMet` - Preconditions failed, resources not created
- `ResourceCreationFailed` - Failed to create resources

**Example**:
```json
{
  "type": "Applied",
  "status": "True",
  "reason": "ResourcesCreated",
  "message": "All Kubernetes resources created successfully",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}
```

### 2. Available

**Purpose**: Has the adapter completed its work successfully?

**Meaning**:
- `True` - Adapter finished successfully, all requirements met, workload completed
- `False` - Adapter failed, incomplete, or still in progress

**Status Values**:
- `True` - Workload completed successfully
- `False` - Workload in progress, failed, or not started

**Common Reasons**:
- `JobSucceeded` - Job/workload completed successfully
- `PostconditionsMet` - All postconditions satisfied
- `JobRunning` - Job/workload still executing
- `PostconditionsNotMet` - Postconditions not satisfied yet
- `JobFailed` - Job/workload failed
- `PreconditionsNotMet` - Cannot start (preconditions not met)

**Example**:
```json
{
  "type": "Available",
  "status": "True",
  "reason": "JobSucceeded",
  "message": "Validation Job completed successfully",
  "lastTransitionTime": "2025-10-17T12:02:00Z"
}
```

### 3. Health

**Purpose**: Is the adapter healthy (no errors, no failures)?

**Meaning**:
- `True` - Adapter is healthy, no errors detected
- `False` - Adapter encountered errors or failures

**Status Values**:
- `True` - No errors, adapter is healthy
- `False` - Errors detected, adapter is unhealthy

**Common Reasons**:
- `AllChecksPass` - All health checks passed
- `NoErrors` - No errors detected
- `AdapterError` - Adapter encountered an internal error
- `KubernetesAPIFailure` - Failed to connect to Kubernetes API
- `ResourceFailure` - Resource failures detected

**Example**:
```json
{
  "type": "Health",
  "status": "True",
  "reason": "AllChecksPass",
  "message": "All health checks passed",
  "lastTransitionTime": "2025-10-17T12:00:05Z"
}
```

---

## Status Reporting Patterns

Based on the adapter workflow state, adapters report status using these patterns:

### Pattern 1: Preconditions NOT Met

**When**: Preconditions fail, adapter cannot act

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Dependencies not satisfied: validation adapter not available"
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "PreconditionsNotMet",
      "message": "Cannot proceed until dependencies are satisfied"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy, waiting for dependencies"
    }
  ]
}
```

### Pattern 2: Resources Created

**When**: Resources didn't exist, adapter created them

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "ResourcesCreated",
      "message": "All Kubernetes resources created successfully"
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "WorkloadInProgress",
      "message": "Resources created, workload executing"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "NoErrors",
      "message": "Adapter is healthy"
    }
  ]
}
```

### Pattern 3: Workload In Progress

**When**: Resources exist, postconditions not met yet

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "ResourcesExist",
      "message": "Resources are applied"
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "PostconditionsNotMet",
      "message": "Workload still running, postconditions not satisfied"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPass",
      "message": "All health checks passed"
    }
  ]
}
```

### Pattern 4: Workload Succeeded

**When**: Resources exist, postconditions met, workload succeeded

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "ResourcesExist",
      "message": "Resources are applied"
    },
    {
      "type": "Available",
      "status": "True",
      "reason": "PostconditionsMet",
      "message": "Workload completed successfully, all postconditions satisfied"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "AllChecksPass",
      "message": "All health checks passed"
    }
  ]
}
```

### Pattern 5: Workload Failed

**When**: Resources exist, postconditions met, but workload failed

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "True",
      "reason": "ResourcesExist",
      "message": "Resources are applied"
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "WorkloadFailed",
      "message": "Workload failed: Job exited with error code 1"
    },
    {
      "type": "Health",
      "status": "True",
      "reason": "EventProcessed",
      "message": "Event processed: adapter is in healthy status"
    }
  ]
}
```

### Pattern 6: Adapter Error

**When**: Adapter encountered an internal error

**Status**:
```json
{
  "conditions": [
    {
      "type": "Applied",
      "status": "False",
      "reason": "AdapterError",
      "message": "Failed to connect to Kubernetes API"
    },
    {
      "type": "Available",
      "status": "False",
      "reason": "AdapterError",
      "message": "Adapter cannot perform its work due to internal error"
    },
    {
      "type": "Health",
      "status": "False",
      "reason": "AdapterError",
      "message": "Adapter encountered an error: connection timeout"
    }
  ]
}
```

---

## Optional Fields

### Data Field

The `data` field allows adapters to report structured, adapter-specific information:

**Structure**: Free-form JSON object

**Examples**:

**Validation Adapter**:
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

**DNS Adapter**:
```json
{
  "data": {
    "dnsRecords": [
      {
        "name": "api.cluster.example.com",
        "type": "A",
        "value": "1.2.3.4",
        "created": true
      }
    ],
    "certificates": {
      "apiCert": {
        "name": "api-cluster-example-com",
        "status": "Ready",
        "expiresAt": "2026-10-17T12:00:00Z"
      }
    }
  }
}
```

**Infrastructure Adapter**:
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

### Metadata Field

The `metadata` field allows adapters to report additional metadata:

**Structure**: Free-form JSON object

**Common Fields**:
- `jobName` - Name of Kubernetes Job/workload
- `executionTime` - Time taken to execute
- `resourceNames` - Names of created resources
- `generation` - Generation of resources

**Example**:
```json
{
  "metadata": {
    "jobName": "validation-cls-123-gen1",
    "executionTime": "115s",
    "resourceNames": [
      "validation-cls-123-gen1",
      "validation-config-cls-123-gen1"
    ]
  }
}
```

---

## Framework Integration

### Configuration-Based Status Building

The adapter framework builds status payloads from configuration in `post.parameters.build`:

**Conditions** (from `post.parameters.build.conditions`):
- `applied` - Expression evaluating if resources are applied
- `available` - Expression evaluating if workload is available
- `health` - Expression evaluating adapter health

**Data** (from `post.parameters.build.data`):
- Custom data expressions evaluated against tracked resources
- May reference external resources from other namespaces

**Example Configuration**:
```yaml
post:
  parameters:
    - name: "clusterStatusPayload"
      build:
        conditions:
          applied:
            status:
              expression: |
                resources.clusterNamespace.status.phase == "Active" &&
                resources.clusterController.status.conditions[?(@.type=='Available')].status == "True"
            reason:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='Available')].reason ?? "ResourcesCreated"
            message:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='Available')].message ?? "All Kubernetes resources created successfully"
          available:
            status:
              expression: |
                resources.clusterController.status.readyReplicas > 0 &&
                resources.clusterController.status.replicas == resources.clusterController.status.readyReplicas
            reason:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='Available')].reason ?? "DeploymentReady"
            message:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='Available')].message ?? "Deployment is available"
          health:
            status:
              expression: |
                (resources.clusterController.status.conditions[?(@.type=='ReplicaFailure')].status ?? "False") != "True" &&
                (resources.clusterController.status.unavailableReplicas ?? 0) < 1
            reason:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='ReplicaFailure')].reason ?? "AllChecksPass"
            message:
              expression: |
                resources.clusterController.status.conditions[?(@.type=='ReplicaFailure')].message ?? "All health checks passed"
        data:
          recordCreated:
            expression: |
              resources.exampleResource.status.value != nil
            description: "Example resource must exist"
  postActions:
    - type: "api_call"
      method: "POST"
      endpoint: "{{ .hyperfleetApiBaseUrl }}/api/{{ .hyperfleetApiVersion }}/clusters/{{ .clusterId }}/statuses"
      headers:
        - name: "Authorization"
          value: "Bearer {{ .hyperfleetApiToken }}"
        - name: "Content-Type"
          value: "application/json"
      body: "{{ .clusterStatusPayload }}"
```

### Status Evaluation Flow

1. **Discover Tracked Resources**: Use `track.discovery` rules to find resources
2. **Build Variables Map**: Include `resources.*`, `externalResources.*`, parameters
3. **Evaluate Conditions**: Evaluate CEL expressions for applied, available, health
4. **Evaluate Data**: Evaluate CEL expressions for custom data fields
5. **Build Payload**: Construct status payload with conditions and data
6. **Execute PostActions**: POST to HyperFleet API endpoint

---

## HTTP Headers

### Required Headers

**Authorization**:
```
Authorization: Bearer {hyperfleetApiToken}
```

**Content-Type**:
```
Content-Type: application/json
```

### Example Request

```http
POST /api/v1/clusters/cls-123/statuses HTTP/1.1
Host: api.hyperfleet.example.com
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
Content-Type: application/json

{
  "adapterStatuses": [
    {
      "adapter": "validation",
      "observedGeneration": 1,
      "conditions": [...],
      "data": {...},
      "lastUpdated": "2025-10-17T12:00:05Z"
    }
  ]
}
```

---

## Response Codes

### Success Responses

- `200 OK` - Status upserted successfully (created or updated)

### Error Responses

- `400 Bad Request` - Invalid payload structure
- `401 Unauthorized` - Missing or invalid authentication token
- `404 Not Found` - Cluster not found
- `500 Internal Server Error` - Server error

---

## Best Practices

### 1. Always Include All Three Conditions

Every status update must include Applied, Available, and Health conditions.

### 2. Use Meaningful Reasons

Use consistent reason codes that clearly indicate the state:
- `ResourcesCreated`, `ResourcesExist`, `PreconditionsNotMet`
- `JobSucceeded`, `JobRunning`, `JobFailed`, `PostconditionsMet`
- `AllChecksPass`, `AdapterError`, `KubernetesAPIFailure`

### 3. Provide Clear Messages

Messages should be human-readable and provide context:
- ✅ "Validation Job completed successfully after 115 seconds"
- ❌ "Done"

### 4. Update lastTransitionTime Correctly

Only update `lastTransitionTime` when the condition status actually changes (True ↔ False).

### 5. Report observedGeneration

Always report the cluster generation you've reconciled to enable generation tracking.

### 6. Use Data Field for Structured Information

Use the `data` field for adapter-specific structured data that other components might need.

### 7. Handle Errors Gracefully

Report adapter errors with `Health=False` and appropriate error messages.

### 8. Always Use POST

Always POST to the same endpoint - the API handles upsert logic server-side for idempotency.

---

## Versioning

This contract is versioned with the HyperFleet API version. Adapters must use the API version specified in their configuration (`hyperfleetApiVersion`).

**Current Version**: `v1`

---

## References

- [Kubernetes Conditions](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-conditions) - Inspiration for condition structure
- [Status Guide](../../docs/status-guide.md) - Comprehensive status guide
- [Adapter Framework Design](./adapter-frame-design.md) - Framework architecture

