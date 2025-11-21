# SPIKE REPORT: Define Validation Adapter Criteria and Implementation Plan for GCP
**JIRA Story**: [HYPERFLEET-59](https://issues.redhat.com/browse/HYPERFLEET-59)  
**Prepared By**: dawang@redhat.com  
**Date**: November 21, 2025  
**Status**: Reviewing  
**Reviewers**:

---

## 1. Executive Summary

This spike defines a **phased implementation approach** for a GCP validation adapter that runs as a Kubernetes Job to validate GCP prerequisites before cluster provisioning. The solution is based on proven patterns from the existing uhc-clusters-service (CS) [GCP preflight logic](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go), adapted for the adapter framework context.

### Key Decisions
- **Deployment**: Validation adapter runs as a Kubernetes Job in a GKE cluster
- **Implementation Vehicle**: Two-container sidecar pattern (validator + status reporter)
- **Architecture**: GCP validator container + reusable status reporter sidecar
- **Authentication**: Workload Identity Federation (WIF)
- **Validation Flow**:
  1. Verify WIF is configured (annotation exists on K8s SA)
  2. Use WIF to check APIs enabled in customer's project
  3. (Post-MVP) Use WIF to check quota available in customer's project
  4. (Post-MVP) Use WIF for network, IAM, region validation
- **Status Reporting**: Sidecar container reads results from shared volume (e.g., EmptyDir), updates Job status

### Primary Risk
Ensuring proper IAM permission configuration for Workload Identity integration within the Job context, especially for GCP cross-project validation scenarios.

---

## 2. Exploration Summary: K8s Job vs Tekton Pipeline

Two implementation approaches were evaluated:

1. **Kubernetes Job (Selected)**: Self-contained, simpler deployment model, native K8s failure handling, minimal external dependencies. More details refer to [update-job-status](https://gitlab.cee.redhat.com/amarin/update-job-status/).
2. **Tekton Pipeline (Deferred)**: More complex orchestration capabilities, better suited for multi-stage workflows, requires Tekton operator installation. More details refer to [validation-pipeline-demo](https://github.com/86254860/validation-pipeline-demo).

**Decision**: K8s Job selected for initial implementation due to lower operational overhead and alignment with validation use case requirements.

## 3. GCP Validation Requirements (Based on CS GCP Preflight Logic)

The validation requirements are derived from the production GCP preflight implementation in [uhc-clusters-service](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go). This ensures alignment with proven validation patterns.

### 3.1 Credential Validation (MVP TBD)

**Purpose**: Verify that Workload Identity Federation (WIF) is configured for the validation Job.

**Validation Flow**:
```
Kubernetes Job Pod
├── Step 1: Check if WIF is configured
│
├── Step 2: If WIF exists → Continue to API validation
│   └── API validator will use WIF to check APIs in customer's project
│
└── Step 3+: (Post-MVP) More validators use WIF
    ├── Quota validator
    ├── Network validator
    └── IAM validator
```

**Note**: At initial phase, credential validation only checks if WIF annotation exists. Actual authentication and authorization testing happens when API validator (or other validators) attempt to use WIF.

### 3.2 Required GCP APIs (MVP TBD)

**Implementation Reference**: [CS Required GCP APIs](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L44-L63)

The following APIs **must be enabled** before cluster provisioning:

| API Service | Purpose |
|------------|---------|
| `compute.googleapis.com` | Compute Engine (VMs, networks, disks) |
| `iam.googleapis.com` | Identity and Access Management |
| `cloudresourcemanager.googleapis.com` | Project metadata access |
| `serviceusage.googleapis.com` | Quota limit queries |
| `monitoring.googleapis.com` | Quota usage metrics |
| `dns.googleapis.com` | Cloud DNS management |
| `container.googleapis.com` | GKE features |

### 3.3 GCP Quota Validation (Post-MVP)
**Implementation Reference**: [CS quota preflight logic](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L190-L191)  

**Regional vCPU Quota Validation Flow**:
```
1. Get project number from project ID
2. Query current vCPU usage (Monitoring API MQL query)
3. Get regional quota limit (Service Usage API - use EffectiveLimit)
4. Calculate: Available = Limit - Usage
5. Validate: Required vCPUs ≤ Available Quota
```

**Required SDK Methods**:
```go
// Step 1: Get project number
import resourcemanager "google.golang.org/api/cloudresourcemanager/v1"
project, _ := crmService.Projects.Get(projectID).Context(ctx).Do()
projectNumber := project.ProjectNumber

// Step 2: Query current vCPU usage
import monitoring "google.golang.org/api/monitoring/v3"
const vCPUUsageQuery = `fetch consumer_quota
| metric 'serviceruntime.googleapis.com/quota/allocation/usage'
| filter  (resource.service == 'compute.googleapis.com')
    && (metric.quota_metric == 'compute.googleapis.com/cpus')
| group_by 1d, [value_usage : max(value.usage)]`

response, _ := monitoringService.Projects.TimeSeries.Query(projectPath, queryRequest).Do()
currentUsage := response.TimeSeriesData[0].PointData[0].Values[0].Int64Value

// Step 3: Get regional quota limit
import serviceusage "google.golang.org/api/serviceusage/v1beta1"
const cpuQuotaMetric = "/services/compute.googleapis.com/consumerQuotaMetrics/compute.googleapis.com%2Fcpus"
metrics, _ := serviceUsageService.Services.ConsumerQuotaMetrics.Get(metricPath).Do()
// Find regional bucket and extract EffectiveLimit
```

**Required IAM Permissions**:
- `monitoring.timeSeries.list` - Query vCPU usage
- `serviceusage.services.get` - Retrieve service info
- `serviceusage.quotas.get` - Get quota limits
- `resourcemanager.projects.get` - Get project metadata

**Quota Calculation Example**:
```
Required vCPUs = Σ (node_count × vCPUs_per_machine_type)
Example:
  - default-pool: 3 nodes × 4 vCPUs (n1-standard-4) = 12 vCPUs
  - compute-pool: 2 nodes × 8 vCPUs (n2-standard-8) = 16 vCPUs
  Total Required: 28 vCPUs

If Regional Limit = 100, Current Usage = 80:
  Available = 100 - 80 = 20 vCPUs
  Validation FAILS (28 > 20)
```

**Extended Quota Validation**:
- Service Account quota (`iam.googleapis.com/quota/service_account_count`)
- Regional external IP addresses
- Persistent disk quota (pd-standard, pd-ssd)
- GPU quotas (if applicable)

### 3.4 Network Configuration Validation (Post-MVP)

**Implementation Reference**: [CS network preflight](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go#L188-196)  

#### VPC and Subnet Existence

**Skip Condition**: Empty VPC name (default VPC scenario)

**Validation Logic**:
```go
// 1. Resolve VPC Project ID (support shared VPC)
vpcProjectId := gcp.ProjectID
if gcp.VpcNetworkProjectId != "" {
    vpcProjectId = gcp.VpcNetworkProjectId
}

// 2. Validate VPC Project exists
import cloudresourcemanager "google.golang.org/api/cloudresourcemanager/v1"
projects, _ := crmService.Projects.List().Context(ctx).Do()
// Verify vpcProjectId in projects list

// 3. Validate VPC Network exists
import compute "google.golang.org/api/compute/v1"
network, err := computeService.Networks.Get(vpcProjectId, vpcName).Context(ctx).Do()
if err != nil {
    return fmt.Errorf("VPC network %s not found in project %s", vpcName, vpcProjectId)
}

// 4. List subnets in target region
filter := fmt.Sprintf("network eq .*%s", vpcName)
req := computeService.Subnetworks.List(vpcProjectId, region).Filter(filter)
var subnets []*compute.Subnetwork
req.Pages(ctx, func(page *compute.SubnetworkList) error {
    subnets = append(subnets, page.Items...)
    return nil
})

// 5. Verify required subnets exist
// Check control plane subnet
// Check compute subnet
```

**Required IAM Permissions**:
- `compute.networks.get` - Retrieve VPC details
- `compute.subnetworks.list` - List subnets
- `compute.subnetworks.get` - Get subnet details
- `resourcemanager.projects.list` - List projects (for shared VPC)

#### CIDR Containment Validation (Post-MVP)

**Skip Condition**: Non-BYO VPC deployments

**Validation Logic**:
```go
// Validate Machine CIDR contains subnet CIDRs
import "net"
_, machineCIDRNet, _ := net.ParseCIDR(machineCIDR)

for _, subnetCIDR := range subnetCidrs {
    subnetIP, subnetNet, _ := net.ParseCIDR(subnetCIDR)
    
    // Check if subnet's first IP is within Machine CIDR
    if !machineCIDRNet.Contains(subnetIP) {
        return fmt.Errorf("subnet CIDR %s not contained in machine CIDR %s", 
            subnetCIDR, machineCIDR)
    }
    
    // Additional: Check subnet size is sufficient
    subnetSize := calculateCIDRSize(subnetNet)
    if subnetSize < minimumSubnetSize {
        return fmt.Errorf("subnet %s too small: %d IPs (minimum: %d)", 
            subnetCIDR, subnetSize, minimumSubnetSize)
    }
}
```

### 3.5 Region and Zone Availability (Post-MVP)

#### Region Existence
```go
import compute "google.golang.org/api/compute/v1"

// List all available regions
regions, err := computeService.Regions.Get(projectID, requestedRegion).Context(ctx).Do()
if err != nil {
    return fmt.Errorf("region %s not available", requestedRegion)
}

// Check region status
if regions.Status != "UP" {
    return fmt.Errorf("region %s status is %s", requestedRegion, regions.Status)
}
```

#### Machine Type Availability (Post-MVP)
```go
// Validate machine types exist in target zones
for _, zone := range requestedZones {
    for _, machineType := range requestedMachineTypes {
        mt, err := computeService.MachineTypes.Get(projectID, zone, machineType).Context(ctx).Do()
        if err != nil {
            return fmt.Errorf("machine type %s not available in zone %s", machineType, zone)
        }
    }
}
```

---

## 4. Validation Adapter Related Configurations

### 4.1 Kubernetes Job Manifest Template

First, the validation should run successfully as a Kubernetes Job on the GKE cluster, using a two-container pattern:
- **Validator Container**: Runs GCP validation checks, writes results to shared volume
- **Reporter Sidecar**: Reads results from shared volume, updates Job status/annotation

Here's the example YAML of the GCP validation job.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: gcp-validate-{{.cluster_id}}
  namespace: {{.namespace}}
  labels:
    app: gcp-validator
    cluster-id: "{{.cluster_id}}"
  annotations:
    cluster-name: "{{.cluster_name}}"
    created-by: "adapter-framework"
spec:
  template:
    metadata:
      labels:
        app: gcp-validator
        cluster-id: "{{.cluster_id}}"
    spec:
      serviceAccountName: gcp-validator-sa
      
      # Support Workload Identity
      # Workload Identity annotation (if enabled)=
      annotations:
        iam.gke.io/gcp-service-account: "{{.gcp_sa_email}}"
      
      containers:
      #
      # Container 1: GCP Validator
      # Performs validation checks and writes results to shared volume
      #
      - name: validator
        image: "{{.registry}}/gcp-validator:{{.version}}"
        
        env:
        # Cluster identification
        - name: CLUSTER_ID
          value: "{{.cluster_id}}"
        - name: CLUSTER_NAME
          value: "{{.cluster_name}}"
        
        # Configuration paths
        - name: CLUSTER_CONFIG_PATH
          value: "/etc/cluster-config/cluster.json"
        - name: VALIDATION_RULES_PATH
          value: "/etc/validation-rules/validation-rules.yaml"
        
        # Results output path (shared with reporter sidecar)
        - name: RESULTS_OUTPUT_PATH
          value: "/results/validation-report.json"
        
        volumeMounts:
        - name: cluster-config
          mountPath: /etc/cluster-config
          readOnly: true
        - name: validation-rules
          mountPath: /etc/validation-rules
          readOnly: true
        - name: results
          mountPath: /results
          readOnly: false  # Validator writes results here
        
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      
      #
      # Container 2: Status Reporter Sidecar (Reusable across all validators)
      # Waits for validation results, updates Job status, creates events
      #
      - name: status-reporter
        image: "{{.registry}}/validation-status-reporter:{{.reporter_version}}"
        
        env:
        # K8s resource to update
        - name: JOB_NAME
          value: "gcp-validate-{{.cluster_id}}"
        - name: JOB_NAMESPACE
          value: "{{.namespace}}"
        
        # Results input path (shared with validator)
        - name: RESULTS_INPUT_PATH
          value: "/results/validation-report.json"
        
        # Reporter behavior
        - name: WAIT_TIMEOUT
          value: "300"  # Wait up to 5 minutes for results
        - name: POLL_INTERVAL
          value: "2"    # Check for results every 2 seconds
        
        volumeMounts:
        - name: results
          mountPath: /results
          readOnly: true  # Reporter only reads results
        
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
      
      volumes:
      - name: cluster-config
        configMap:
          name: cluster-config-{{.cluster_id}}
      - name: validation-rules
        configMap:
          name: gcp-validation-rules
      - name: results
        emptyDir: {}  # Shared volume for result communication
      
      restartPolicy: Never
  
  # Job control
  backoffLimit: 2  # Retry up to 2 times on failure
  activeDeadlineSeconds: 300  # 5 minute timeout
  ttlSecondsAfterFinished: 3600  # Clean up after 1 hour
```

### 4.2 ConfigMap 1: Cluster-Specific Configuration

**Purpose**: Contains cluster-specific parameters for a single cluster validation.

**Lifecycle**: Created by adapter framework per cluster, deleted after validation completes.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config-{{.cluster_id}}
  namespace: {{.namespace}}
  labels:
    cluster-id: "{{.cluster_id}}"
data:
  # Refer to https://github.com/openshift-hyperfleet/hyperfleet-api-spec/tree/main
  cluster.json: |
    {
      "cluster_id": "{{.cluster_id}}",
      "cluster_name": "{{.cluster_name}}",
      
      "gcp": {
        "project_id": "{{.gcp_project_id}}",
        "region": "{{.gcp_region}}",
        ...
        }
      }
    }
```

### 4.3 ConfigMap 2: Shared Validation Rules

**Purpose**: Defines validation criteria, thresholds, and rules shared across all GCP validations.

**Lifecycle**: Deployed once per environment, updated via configuration management.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gcp-validation-rules
  namespace: {{.namespace}}
  labels:
    config-type: validation-rules
    provider: gcp
data:
  validation-rules.yaml: |
    # Provider configuration
    provider: gcp
    
    # Global validation settings
    validation:
      enabled: true
      timeout_seconds: 300
      
      # Validation checks to perform
      checks:
        - api_enablement
        - vpc_subnet_existence
        - service_account_existence
        - region_availability
    
    # Required GCP APIs
    required_apis:
      - name: "compute.googleapis.com"
        display_name: "Compute Engine API"
      - name: "iam.googleapis.com"
        display_name: "Identity and Access Management API"
      - name: "cloudresourcemanager.googleapis.com"
        display_name: "Cloud Resource Manager API"
      - name: "serviceusage.googleapis.com"
        display_name: "Service Usage API"
      - name: "monitoring.googleapis.com"
        display_name: "Cloud Monitoring API"
    
    # Quota validation rules
    quota_validation:
      # Buffer to reserve beyond calculated requirement
      buffer_percentage: 20
      
      # Quota metrics to validate
      metrics:
        - metric: "CPUS"
          quota_name: "compute.googleapis.com/cpus"
          minimum_available: 8
          critical: true
        - metric: "DISKS_TOTAL_GB"
          quota_name: "compute.googleapis.com/disks_total_gb"
          minimum_available: 500
          critical: false
        - metric: "IN_USE_ADDRESSES"
          quota_name: "compute.googleapis.com/in_use_addresses"
          minimum_available: 10
          critical: false
    
    # IAM validation rules
    iam_validation:
      required_roles:
        - name: "roles/compute.admin"
        - name: "roles/iam.serviceAccountUser"
        - name: "roles/logging.logWriter"
        - name: "roles/monitoring.metricWriter"
    
    # Error messages and remediation guidance
    error_messages:
      api_not_enabled: |
        API {api_name} is not enabled in project {project_id}.
        
        Remediation:
        gcloud services enable {api_name} --project={project_id}
      
      quota_exceeded: |
        Insufficient {quota_metric} quota in region {region}.
        Required: {required} (including {buffer_percentage}% buffer)
        Available: {available} (Limit: {limit}, Current Usage: {usage})
        
        Remediation:
        Request quota increase: https://console.cloud.google.com/iam-admin/quotas

      ...
```

### 4.4 Workload Identity Configuration

Using GKE Workload Identity:

```yaml
# Kubernetes Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gcp-validator-sa
  namespace: {{.namespace}}
  annotations:
    iam.gke.io/gcp-service-account: "{{.gcp_sa_email}}"

---
# GCP IAM Policy Binding
# Execute via gcloud (not K8s manifest)
# gcloud iam service-accounts add-iam-policy-binding {{.gcp_sa_email}} \
#   --role roles/iam.workloadIdentityUser \
#   --member "serviceAccount:{{.gcp_project_id}}.svc.id.goog[{{.namespace}}/gcp-validator-sa]"
```


### 4.5 GCP Validation Adapter Configuration

After the Kubernetes Job for GCP validation completes, configure the GCP Validation Adapter according to the [latest adapter configuration specification](https://github.com/openshift-hyperfleet/architecture/tree/main/hyperfleet/components/adapter/framework). This ensures the configuration is properly recognized and processed by the adapter framework.

---

## 5. Status Reporter Sidecar (Reusable Component)

### 5.1 Overview

The **Status Reporter Sidecar** is a **cloud-agnostic**, reusable container that handles Job status updates for any validation container. This separation provides:

1. **Reusability**: Same sidecar for GCP, AWS, Azure, or any custom validator
2. **Separation of Concerns**: Validators focus on validation logic, reporter handles K8s integration
3. **Standardization**: Consistent status reporting format across all validators
4. **Simplicity**: Validators don't need K8s client libraries

### 5.2 Communication Pattern

**Shared Volume (emptyDir)**:
- Validator writes `validation-report.json` to `/results/`
- Reporter polls for file existence
- Reporter reads JSON, updates Job, exits

```
┌─────────────────────┐         ┌──────────────────────┐
│  Validator Container│         │ Reporter Sidecar     │
│                     │         │                      │
│  1. Run validation  │         │  1. Poll for file    │
│  2. Generate report │         │     (every 2s)       │
│  3. Write JSON ─────┼────────>│  2. File detected    │
│     to /results/    │ Shared  │  3. Read JSON        │
│  4. Exit (0 or 1)   │ Volume  │  4. Update Job       │
│                     │         │  5. Create Event     │
│                     │         │  6. Exit (0)         │
└─────────────────────┘         └──────────────────────┘
```

### 5.3 Exmaple to Update Job Status
Here's an k8s yaml example to define a status-updater container using kubectl to update the job status.
```
- name: status-updater
        image: bitnami/kubectl:latest
        command:
        - /bin/bash
        - -c
        - |
          set -e

          # Wait for the worker container to finish and create results.json
          echo "Waiting for results.json..."
          while [ ! -f /data/results.json ]; do
            sleep 1
          done

          # Give a moment for the file to be fully written
          sleep 2

          echo "Found results.json, reading contents..."
          cat /data/results.json

          # Get the Job name and namespace from the pod
          JOB_NAME="${JOB_NAME:-result-processor}"
          NAMESPACE="${NAMESPACE:-default}"

          # Read the JSON file and extract values
          AVAILABLE=$(get the validation result from /data/results.json)
          REASON=$(get the failed validation reason from /data/results.json)
          MESSAGE=$(get the validation message from /data/results.json)

          echo "Parsed values - available: $AVAILABLE, message: $MESSAGE

          # Create status patch with conditions
          TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

          # Build conditions array
          CONDITIONS='[
            {
              "type": "Available",
              "status": "'$AVAILABLE'",
              "lastTransitionTime": "'$TIMESTAMP'",
              "reason": "$REASON",
              "message": "$MESSAGE"
            }
          ]'

          echo "Updating Job status with conditions... ${CONDITIONS}"

          # Patch the Job status
          kubectl patch job "$JOB_NAME" -n "$NAMESPACE" \
            --subresource=status \
            --type=merge \
            -p '{"status":{"conditions":'"$CONDITIONS"'}}'

          echo "Status update completed!"
```

**Note:**: It requires related RBAC permissions configuration to update the job status. More details refer to [this](https://gitlab.cee.redhat.com/amarin/update-job-status/-/blob/main/job.yaml).

---

## 6. Implementation Plan

### MVP - Proof of Concept

**Goal**: Prove the adapter framework architecture works end-to-end with GCP validation adapter - fake or minimal validation logic (credentials + 3-4 API checks).

**Scope**: Absolute minimum to validate the solution architecture:
- Status reporter sidecar (basic version)
- GCP validation logic (**Option 1 or 2 is still TBD**, as the required implementation effort differs)
    - Option 1: A fake validation logic
    - Option 2: A real GCP validation logic with TWO validators only:
        - **Credential validation** - Verify GCP credentials exist and are valid
        - **API enablement check** - Check if required APIs are enabled
- Basic integration testing

#### Tasks
- Implement status reporter logic
- Implement GCP validation logic (Option 1 or 2 TBD)
- Write unit tests for smoke tests
- Dockerfile and Makefile for image build and testing
- RBAC and k8s related YAML files for GCP validation job
- The GCP validation adapter configuration
- Integration with Adapter framework (Configuration, Deployment, Testing)
- Write README with setup instructions, deployment instructions

**Success Criteria**:
- The status reporter sidecar runs successfully
- The GCP validation logic runs successfully
- The k8s job (including GCP validation and status reporter containers) runs successfully
    - Results written to shared volume (EmptyDir)
    - Reporter sidecar updates Job status
    - Job status reflects validation result (pass/fail)
- GCP validation adapter (configuration, logic, etc.) works well with the Adapter framework

---

### Post-MVP Enhancements

After MVP is approved and working, implement additional features iteratively.

**Goal**: Make the solution production-ready and add comprehensive validation coverage.

**Production Readiness**:
- ✅ Add Workload Identity authentication support
- ✅ Proper error handling and structured logging
- ✅ Retry logic with exponential backoff
- ✅ ConfigMap-based configuration (replace hardcoded values)
- ✅ Unit tests for both containers (≥80% coverage)
- ✅ Integration tests with test GCP project
- ✅ RBAC resources and security hardening
- ✅ Complete documentation (setup, troubleshooting, runbooks)
- ✅ Complete API enablement checks (all required APIs)

**Additional Validators** (All Post-MVP):
- ✅ VPC/Subnet existence validator
- ✅ Service Account existence validator
- ✅ Region availability validator
- ✅ vCPU quota validation (Monitoring API + Service Usage API)
- ✅ CIDR containment validation
- ✅ IAM role binding validation
- ✅ Machine type availability validation
- ✅ Disk quota validation (pd-standard, pd-ssd)
- ✅ IP address quota validation
- ✅ Service account quota validation
- ✅ IAM permissions testing (TestIamPermissions API)
- ✅ Shared VPC advanced validation
- ✅ Secondary IP ranges validation (GKE)

**Enhanced Features**:
- Enhanced error messages with remediation guidance (gcloud commands)
- Parallel validator execution for performance
- Prometheus metrics export
- E2E test suite
- Performance optimization
- Security scanning

---

## 7. Acceptance Criteria for Implementation Tickets

Based on this spike, implementation tickets should have the following acceptance criteria:

### MVP Acceptance Criteria

**Ticket: GCP Validation MVP - Architecture Proof of Concept**

**Goal**: Prove the adapter framework architecture works end-to-end with GCP validation adapter - fake or minimal validation logic (credentials + 3-4 API checks).

**Status Reporter Sidecar** (Basic):
- [ ] Polls for `/results/validation-report.json` on shared emptyDir volume
- [ ] Reads and parses JSON validation report
- [ ] Updates Job status with validation status
- [ ] Basic timeout handling (5 minute max wait), if validation report file doesn't exist until timeout, Job status is updated to `Failed` with timeout message
- [ ] Dockerfile builds successfully
- [ ] Container image runs in K8s

**GCP Validator** (Fake logic or minimal validation logic):  

- // **Option 1:** A fake validation logic  
- [ ] Implement GCP fake validation logic
  - Returns Success if all checks pass
  - Returns Failure if any check fails
- // **Option 2:** A real GCP validation logic with TWO validators only:
- [ ] **Workload Identity Federation** (WIF) for GCP authentication
  - How to setup WIF to access customer's GCP project 
  - How to pass WIF to validator container
- [ ] Implements **Validator 1: WIF Configuration Check**
  - Checks if K8s Service Account has `iam.gke.io/gcp-service-account` annotation
  - Returns Success if annotation exists, Failure if missing
  - Does NOT test if WIF actually works (deferred to API validator)
- [ ] Implements **Validator 2: API Enablement Check** (first to use WIF)
  - Attempts to use WIF to authenticate with GCP
  - Checks if 3-4 critical APIs are enabled in customer's project:
    - `compute.googleapis.com`
    - `iam.googleapis.com`
    - `cloudresourcemanager.googleapis.com`
  - Returns Success if can authenticate AND APIs are enabled
  - Returns Failure if WIF doesn't work OR APIs are disabled
    

- [ ] Writes results to `/results/validation-report.json` (valid JSON schema)
- [ ] Exits with code 0 (success) or 1 (failure)
- [ ] Dockerfile builds successfully
- [ ] Container image runs in K8s

**Integration**:
- [ ] Job manifest with two containers (validator + reporter)
- [ ] Shared emptyDir volume mounted at `/results/` in both containers
- [ ] Minimal ConfigMap with project ID and API list
- [ ] Job deploys and runs in K8s cluster
- [ ] Job status show validation result after completion
- [ ] GCP validation YAML file for adapter framework

**Deliverables**:
- [ ] Two working containers (reporter + validator)
- [ ] Job manifest YAML
- [ ] GCP validation YAML file for adapter framework
- [ ] Basic README
- [ ] Demo showing end-to-end flow with both validators

---

## References

### GCP Documentation
- [GCP Go SDK](https://pkg.go.dev/google.golang.org/api)
- [Compute Engine API](https://cloud.google.com/compute/docs/reference/rest/v1)
- [Service Usage API](https://cloud.google.com/service-usage/docs/reference/rest)
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [IAM Permissions Reference](https://cloud.google.com/iam/docs/permissions-reference)

### Internal References
- [uhc-clusters-service GCP Preflight](https://gitlab.cee.redhat.com/service/uhc-clusters-service/-/blob/master/cmd/clusters-service/service/gcp_preflight/preflight_service.go)
- [Adapter Framework Documentation](https://github.com/openshift-hyperfleet/architecture/tree/main/hyperfleet/components/adapter/framework)

### Kubernetes Documentation
- [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Job Status and Conditions](https://kubernetes.io/docs/concepts/workloads/controllers/job/#job-status)

---



