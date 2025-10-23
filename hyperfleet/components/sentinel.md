## What & Why

**What**

Implement a "HyperFleet Sentinel" service that continuously polls the HyperFleet API for resources (clusters, node pools, etc.) and publishes reconciliation events directly to the message broker to trigger adapter processing. The Sentinel acts as the "watchful guardian" of the HyperFleet system with simple, configurable backoff intervals. Multiple Sentinel deployments can be configured via YAML configuration files to handle different shards of resources for horizontal scalability.

**Pattern Reusability**: The Sentinel is designed as a generic reconciliation operator that can watch ANY HyperFleet resource type, not just clusters. Future deployments can include:
- **Cluster Sentinel** (this epic) - watches clusters
- **NodePool Sentinel** (future) - watches node pools
- **[Resource] Sentinel** (future) - watches any HyperFleet resource

**Why**

Without the Sentinel, the cluster provisioning workflow has a critical gap:

1. **No Reconciliation Loop**: After adapters complete their work and post status updates, nothing triggers subsequent adapters to check if they can now proceed
2. **Stuck Clusters**: Clusters remain in "pending" state indefinitely with no mechanism to retry failed operations
3. **Manual Intervention Required**: Operators must manually trigger reconciliation or restart adapters
4. **No Failure Recovery**: Transient failures cannot self-heal without a retry mechanism

The Sentinel solves these problems by:
- **Closing the reconciliation loop**: Continuously polls resources and publishes events to trigger adapter evaluation
- **Uses adapter status updates**: Reads `status.lastTransitionTime` (updated by adapters) to determine when to create next event
- **Simple backoff**: 10 seconds for non-ready resources, 30 minutes for ready resources (configurable)
- **Self-healing**: Automatically retries without manual intervention
- **Horizontal scalability**: Sharding support allows multiple Sentinels to handle different resource subsets
- **Event-driven architecture**: Maintains decoupling by publishing CloudEvents to message broker
- **Reusable pattern**: Same operator can watch clusters, node pools, or any future HyperFleet resource
- **Direct publishing**: Publishes events directly to broker, simplifying architecture (no outbox pattern needed)

**Acceptance Criteria:**

- Configuration schema defined in Go structs with proper validation tags
- Service deployed as single replica per shard
- Service reads configuration from YAML files with environment variable overrides
- Polls HyperFleet API for resources matching shard criteria
- Uses `status.lastTransitionTime` from adapter status updates for backoff calculation
- Creates CloudEvents for resources based on simple decision logic
- Publishes events directly to message broker (GCP Pub/Sub or RabbitMQ)
- Configurable backoff intervals (not-ready vs ready)
- Sharding support via label selectors in configuration
- Metrics exposed for monitoring (reconciliation rate, event publishing, errors)
- Integration tests verify decision logic and backoff behavior with adapter status updates
- Graceful shutdown and error handling implemented
- Multiple services can run simultaneously with different shards

---

## Sentinel Architecture

### The Problem: Stuck Workflows

**Without Sentinel**:
```
User creates cluster
  → Validation adapter processes
  → Validation reports status
  → STUCK - Nothing triggers next check

Adapter fails transiently
  → STUCK - No retry mechanism
```

### The Solution: Continuous Reconciliation with Direct Broker Publishing

**Reconciliation Loop (Per Shard)**:

```mermaid
flowchart TD
    Init([Service Startup]) --> ReadConfig[Load YAML Configuration<br/>- backoffNotReady: 10s<br/>- backoffReady: 30m<br/>- shardSelector: region=us-east<br/>- broker configuration]

    ReadConfig --> Validate{Configuration<br/>Valid?}
    Validate -->|No| Exit[Exit with Error]
    Validate -->|Yes| StartLoop([Start Polling Loop])

    StartLoop --> FetchClusters[Fetch Clusters with Shard Filter<br/>GET /api/hyperfleet/v1/clusters<br/>?labels=region=us-east]

    FetchClusters --> ForEach{For Each Cluster}

    ForEach --> CheckReady{Cluster Status<br/>== Ready?}

    CheckReady -->|No - NOT Ready| CheckBackoffNotReady{lastTransitionTime + 10s<br/>< now?}
    CheckReady -->|Yes - Ready| CheckBackoffReady{lastTransitionTime + 30m<br/>< now?}

    CheckBackoffNotReady -->|Yes - Expired| PublishEvent[Create CloudEvent<br/>Publish to Broker]
    CheckBackoffNotReady -->|No - Not Expired| Skip[Skip<br/>Backoff not expired]

    CheckBackoffReady -->|Yes - Expired| PublishEvent
    CheckBackoffReady -->|No - Not Expired| Skip

    PublishEvent --> NextCluster{More Clusters?}
    Skip --> NextCluster

    NextCluster -->|Yes| ForEach
    NextCluster -->|No| Sleep[Sleep Poll Interval<br/>5 seconds]

    Sleep --> StartLoop

    style Init fill:#d4edda
    style ReadConfig fill:#fff3cd
    style Validate fill:#fff3cd
    style Exit fill:#f8d7da
    style StartLoop fill:#e1f5e1
    style PublishEvent fill:#ffe1e1
    style Skip fill:#e1e5ff
    style FetchClusters fill:#fff4e1
    style Sleep fill:#f0f0f0
```

**Multiple Operator Deployments (Sharding)**:

```mermaid
graph LR
    subgraph US-East["Cluster Sentinel (us-east)"]
        direction TB
        Config1[YAML Config:<br/>sentinel-us-east.yaml]
        Shard1[Shard Selector:<br/>region=us-east]
        Config1 --> Shard1
    end

    subgraph US-West["Cluster Sentinel (us-west)"]
        direction TB
        Config2[YAML Config:<br/>sentinel-us-west.yaml]
        Shard2[Shard Selector:<br/>region=us-west]
        Config2 --> Shard2
    end

    subgraph EU-West["Cluster Sentinel (eu-west)"]
        direction TB
        Config3[YAML Config:<br/>sentinel-eu-west.yaml]
        Shard3[Shard Selector:<br/>region=eu-west]
        Config3 --> Shard3
    end

    API[HyperFleet API<br/>/clusters]
    Broker[Message Broker<br/>GCP Pub/Sub / RabbitMQ]

    Shard1 -.->|Fetches only<br/>region=us-east| API
    Shard2 -.->|Fetches only<br/>region=us-west| API
    Shard3 -.->|Fetches only<br/>region=eu-west| API

    Shard1 -->|Publish CloudEvents| Broker
    Shard2 -->|Publish CloudEvents| Broker
    Shard3 -->|Publish CloudEvents| Broker

    style US-East fill:#e1f5e1
    style US-West fill:#e1e5ff
    style EU-West fill:#ffe1e1
    style API fill:#fff4e1
    style Broker fill:#ffd4a3
```

**Note on Sharding Flexibility**:

Sharding can be based on **any label criteria** of the cluster object being reconciled. The `shardSelector` uses standard Kubernetes label selectors, allowing for flexible sharding strategies:

- **Regional sharding**: `region=us-east`, `region=eu-west` (as shown above)
- **Environment-based**: `environment=production`, `environment=development`
- **Tenant/Customer**: `customer-id=acme-corp`, `tenant=customer-123`
- **Cluster type**: `cluster-type=hypershift`, `cluster-type=standalone`
- **Priority**: `priority=critical`, `priority=standard`
- **Cloud provider**: `cloud-provider=aws`, `cloud-provider=gcp`
- **Complex selectors**: Using `matchExpressions` for advanced filtering (e.g., `region in (us-east-1, us-east-2)`)

This flexibility allows you to:
- Scale horizontally by dividing clusters across multiple operators
- Isolate blast radius (failures in one shard don't affect others)
- Optimize configurations per shard (different backoff intervals for prod vs dev)
- Deploy operators close to their managed clusters (regional operators in regional k8s clusters)

### Decision Logic (Simplified for MVP)

The operator uses extremely simple decision logic:

**Publish Event IF**:
1. Cluster status is NOT "Ready" AND backoffNotReady interval expired (10 seconds default)
2. OR Cluster status IS "Ready" AND backoffReady interval expired (30 minutes default)

**Skip (Backoff) IF**:
- Not enough time has passed since last event (based on cluster ready state)

**No complex checks**:
- No observedGeneration comparison
- No adapter status evaluation
- No retry-able failure detection
- Just simple time-based event publishing

### Backoff Strategy (MVP Simple)

The operator uses two configurable backoff intervals:

| Cluster State | Backoff Time | Reason |
|---------------|--------------|--------|
| NOT Ready     | 10 seconds   | Cluster being provisioned - check frequently |
| Ready         | 30 minutes   | Cluster stable - periodic health check |

**Configuration** (via YAML file):
```yaml
# Sentinel Configuration for US East
resource_type: clusters  # Resource to watch: clusters, nodepools, manifests, workloads

# Polling configuration
poll_interval: 5s
backoff_not_ready: 10s   # Backoff when resource status != "Ready"
backoff_ready: 30m       # Backoff when resource status == "Ready"

# Shard selector - only process resources matching these labels
shard_selector: "region=us-east"

# HyperFleet API configuration
hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s
  # token: Override via HYPERFLEET_API_TOKEN="secret-token"

# Message broker configuration
broker:
  type: gcp-pubsub
  topic: hyperfleet-events
  project_id: hyperfleet-prod
  # credentials: Override via BROKER_CREDENTIALS="path/to/credentials.json"

  # Alternative for RabbitMQ:
  # type: rabbitmq
  # url: amqp://guest:guest@rabbitmq:5672/
  # exchange: hyperfleet-events
  # credentials: Override via BROKER_CREDENTIALS="sentinel-user:secret-password"
```

**Status Tracking**:

The Sentinel uses the resource's status `lastTransitionTime` to determine when the last status change occurred (from adapter status updates):

```json
{
  "id": "cls-123",
  "status": {
    "phase": "Provisioning",
    "lastTransitionTime": "2025-10-21T12:00:00Z"
  }
}
```

When adapters post status updates, they update the `lastTransitionTime`, which the Sentinel uses for backoff calculation.

### Sharding Architecture

**Why Sharding?**
- Horizontal scalability - distribute load across multiple operators
- Regional isolation - deploy operator per region
- Blast radius reduction - failures affect only one shard
- Flexibility - different configurations per shard (e.g., different backoff for dev vs prod)

**How Sharding Works**:
1. Each Sentinel deployment uses ONE YAML configuration file
2. Configuration file defines `resource_type` (clusters, nodepools, etc.) and `shard_selector` (label selector)
3. Sentinel only fetches resources matching the resource type and shard selector
4. Multiple Sentinels can run simultaneously with non-overlapping selectors
5. Each Sentinel publishes to the same broker topic/exchange (fan-out to adapters)

**Example Sharding Strategy**:

```yaml
# File: sentinel-us-east.yaml
# Deployment 1: US East clusters
resource_type: clusters
poll_interval: 5s
backoff_not_ready: 10s
backoff_ready: 30m
shard_selector: "region=us-east"

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s

broker:
  type: gcp-pubsub
  topic: hyperfleet-events
  project_id: hyperfleet-prod

---
# File: sentinel-us-west.yaml
# Deployment 2: US West clusters (different config!)
resource_type: clusters
poll_interval: 5s
backoff_not_ready: 15s  # Different backoff!
backoff_ready: 1h       # Different backoff!
shard_selector: "region=us-west"

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s

broker:
  type: gcp-pubsub
  topic: hyperfleet-events
  project_id: hyperfleet-prod

---
# File: sentinel-nodepools.yaml
# Future: NodePool Sentinel (different resource type!)
resource_type: nodepools
poll_interval: 5s
backoff_not_ready: 5s
backoff_ready: 10m
# shard_selector: "" # Watch all node pools

hyperfleet_api:
  endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
  timeout: 10s

broker:
  type: gcp-pubsub
  topic: hyperfleet-events
  project_id: hyperfleet-prod
```

---

## Service Components

### 1. Config Loader

**Responsibility**: Load configuration from YAML files with environment variable overrides

**Key Functions**:
- `Load(configPath)` - Load configuration from YAML file
- `BuildLabelSelector(cfg)` - Convert `shard_selector` to label selector

**Implementation Requirements**:
- Load configuration from YAML file path specified via command-line flag
- Parse duration strings (backoff_not_ready, backoff_ready, poll_interval, timeout)
- Parse resource_type field to determine which HyperFleet resources to fetch
- Parse broker configuration (type, topic, credentials)
- Support environment variable overrides for sensitive fields (API tokens, credentials)
- Handle missing or invalid configuration gracefully
- Return structured configuration object for use by reconciler
- Validate required fields and enum values

### 2. Resource Watcher

**Responsibility**: Fetch resources from HyperFleet API with shard filtering

**Key Functions**:
- `FetchResources(ctx, resourceType, selector)` - Fetch resources matching label selector

**Implementation Requirements**:
- Call HyperFleet API: `GET /api/hyperfleet/v1/{resourceType}?labels=<selector>`
- Encode label selector as query parameter
- Handle empty selector (fetch all resources)
- Return list of resource objects with status fields (phase, lastTransitionTime)
- Handle API errors and timeouts gracefully
- Parse status information including `status.lastTransitionTime` from adapter updates

### 3. Decision Engine (Simplified)

**Responsibility**: Simple time-based decision logic based on adapter status updates

**Key Functions**:
- `Evaluate(resource, now)` - Determine if resource needs an event

**Decision Logic**:
1. Check resource.status.phase
2. Select appropriate backoff interval:
   - If phase == "Ready" → use `backoffReady` (30 minutes)
   - If phase != "Ready" → use `backoffNotReady` (10 seconds)
3. Check if backoff expired:
   - Get `resource.status.lastTransitionTime` (updated by adapters when they post status)
   - Calculate `nextEventTime = lastTransitionTime + backoff`
   - If `now >= nextEventTime` → publish event
   - Otherwise → skip (backoff not expired)
4. Return decision with reason for logging

**Key Insight**: Adapters post status updates to the HyperFleet API, which updates `status.lastTransitionTime`. The Sentinel uses this timestamp to determine when enough time has passed since the last adapter status update to warrant publishing another reconciliation event. This creates a feedback loop:
- Adapter processes resource → Posts status update → Updates `lastTransitionTime`
- Sentinel polls resources → Checks `lastTransitionTime` + backoff → Publishes event if expired
- Event triggers adapters → Adapters check preconditions → Post status → Updates `lastTransitionTime`
- Loop continues...

**Implementation Requirements**:
- Simple time-based comparison only
- Use `status.lastTransitionTime` from adapter status updates
- No complex adapter status checks
- No generation/observedGeneration logic
- Clear logging of decision reasoning

### 4. Message Publisher

**Responsibility**: Publish CloudEvents to message broker

**Key Functions**:
- `PublishEvent(ctx, resource, reason)` - Publish CloudEvent to broker

**CloudEvent Format** (CloudEvents 1.0):
```json
{
  "specversion": "1.0",
  "type": "com.redhat.hyperfleet.cluster.reconcile",
  "source": "hyperfleet-sentinel",
  "id": "evt-abc123",
  "time": "2025-10-21T12:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "resourceType": "clusters",
    "resourceId": "cls-123",
    "reason": "backoff-expired"
  }
}
```

**Implementation Requirements**:
- Support GCP Pub/Sub:
  - Use `cloud.google.com/go/pubsub` SDK
  - Publish to configured topic
  - Include CloudEvent attributes as message attributes
- Support RabbitMQ:
  - Use `github.com/rabbitmq/amqp091-go` SDK
  - Publish to configured exchange with routing key
  - Use fanout exchange for adapter broadcast
- Handle publishing errors gracefully
- Log event publishing success/failure
- Return error if publish fails
- Include retry logic with exponential backoff

### 5. Main Reconciler

**Responsibility**: Orchestrate reconciliation loop with periodic polling

**Key Functions**:
- `Run(ctx)` - Main reconciliation loop
- `Start()` - Initialize and start the service

**Initialization Steps** (executed once at startup):
1. **Load Configuration**:
   - Load configuration from YAML file specified via command-line flag
   - Parse backoff intervals, shard selector, broker config, and resource type
   - Apply environment variable overrides for sensitive fields
   - Initialize MessagePublisher with broker config
   - Log configuration details and validate all required fields

**Polling Loop Steps** (repeated every poll_interval):
1. **Fetch Resources**:
   - Build label selector from shard configuration
   - Determine resource endpoint from resource_type (e.g., /clusters, /nodepools)
   - Call ResourceWatcher.FetchResources(ctx, resourceType, selector)
   - Log resource count and shard information
   - Record metric for pending resources

2. **Evaluate Each Resource**:
   - For each resource, call DecisionEngine.Evaluate(resource, now)
   - If decision is "publish event":
     - Create CloudEvent with resource metadata
     - Call MessagePublisher.PublishEvent(ctx, event)
     - Log event publishing
     - Increment events_published metric
     - Continue to next resource on error (don't stop reconciliation)
   - If decision is "skip":
     - Log skip reason at debug level
     - Increment resources_skipped metric

3. **Sleep and Repeat**:
   - Sleep for configured poll_interval (default: 5 seconds)
   - Repeat the loop

**Service Architecture**:
- **Single-phase initialization**: Load configuration once during startup, fail fast if invalid
- **Stateless polling loop**: No configuration reloading during runtime
- **Simple service model**: No Kubernetes controller pattern, just periodic polling
- **Graceful shutdown**: Support clean termination on SIGTERM/SIGINT

**Error Handling**:
- On config load failure: exit with error code
- On resource fetch failure: log error, wait poll interval, retry
- On event publishing failure: log error, record metric, continue to next resource

---

## Service Deployment

### Kubernetes Deployment (Single Replica, No Leader Election)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel
  namespace: hyperfleet-system
  labels:
    app: cluster-sentinel
    app.kubernetes.io/name: hyperfleet-sentinel
    app.kubernetes.io/component: operator
    sentinel.hyperfleet.io/resource-type: clusters
spec:
  replicas: 1  # Single replica per shard
  selector:
    matchLabels:
      app: cluster-sentinel
  template:
    metadata:
      labels:
        app: cluster-sentinel
    spec:
      serviceAccountName: hyperfleet-sentinel
      containers:
      - name: sentinel
        image: quay.io/hyperfleet/sentinel:v1.0.0
        imagePullPolicy: IfNotPresent
        command:
        - /sentinel
        args:
        - --config=/etc/sentinel/config.yaml  # Path to YAML config file
        - --metrics-bind-address=:8080
        - --health-probe-bind-address=:8081
        env:
        # HYPERFLEET_API_TOKEN="secret-token"
        - name: HYPERFLEET_API_TOKEN
          valueFrom:
            secretKeyRef:
              name: sentinel-secrets
              key: api-token
        # GCP_PROJECT_ID="production-project"
        - name: GCP_PROJECT_ID
          valueFrom:
            configMapKeyRef:
              name: sentinel-config
              key: gcp-project-id
        # BROKER_CREDENTIALS="path/to/credentials.json"
        - name: BROKER_CREDENTIALS
          valueFrom:
            secretKeyRef:
              name: sentinel-secrets
              key: broker-credentials
        volumeMounts:
        - name: config
          mountPath: /etc/sentinel
          readOnly: true
        - name: gcp-credentials
          mountPath: /var/secrets/google
          readOnly: true
        ports:
        - containerPort: 8080
          name: metrics
          protocol: TCP
        - containerPort: 8081
          name: health
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: health
          initialDelaySeconds: 15
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /readyz
            port: health
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
      volumes:
      - name: config
        configMap:
          name: sentinel-config
      - name: gcp-credentials
        secret:
          secretName: gcp-pubsub-credentials
```

### ServiceAccount and RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hyperfleet-sentinel
  namespace: hyperfleet-system
---
# ConfigMap with sentinel configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: sentinel-config
  namespace: hyperfleet-system
data:
  config.yaml: |
    resource_type: clusters
    poll_interval: 5s
    backoff_not_ready: 10s
    backoff_ready: 30m
    shard_selector: "region=us-east"

    hyperfleet_api:
      endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
      timeout: 30s

    broker:
      type: gcp-pubsub
      topic: hyperfleet-events
      project_id: hyperfleet-prod
  gcp-project-id: "hyperfleet-prod"
---
# Secret with sensitive configuration
apiVersion: v1
kind: Secret
metadata:
  name: sentinel-secrets
  namespace: hyperfleet-system
type: Opaque
data:
  api-token: <base64-encoded-api-token>
  broker-credentials: <base64-encoded-credentials>
```

**Note**: No RBAC needed since the service only reads configuration from mounted ConfigMap and Secret volumes. No Kubernetes API access required.

---

## Metrics and Observability

### Prometheus Metrics

The Sentinel service must expose the following Prometheus metrics:

| Metric Name | Type | Labels | Description |
|-------------|------|--------|-------------|
| `hyperfleet_sentinel_pending_resources` | Gauge | `shard`, `resource_type` | Number of resources in this shard |
| `hyperfleet_sentinel_events_published_total` | Counter | `shard`, `resource_type` | Total number of events published to broker |
| `hyperfleet_sentinel_resources_skipped_total` | Counter | `shard`, `resource_type`, `ready_state` | Total number of resources skipped due to backoff |
| `hyperfleet_sentinel_poll_duration_seconds` | Histogram | `shard`, `resource_type` | Time spent in each polling cycle |
| `hyperfleet_sentinel_api_errors_total` | Counter | `shard`, `resource_type`, `operation` | Total API errors by operation (fetch_resources, config_load) |
| `hyperfleet_sentinel_broker_errors_total` | Counter | `shard`, `resource_type`, `broker_type` | Total broker publishing errors |
| `hyperfleet_sentinel_config_loads_total` | Counter | `shard`, `resource_type` | Total configuration loads at startup |

**Implementation Requirements**:
- Use standard Prometheus Go client library
- All metrics must include `shard` label (from shard selector string)
- All metrics must include `resource_type` label (from configuration resource_type field)
- `ready_state` label values: "ready" or "not_ready"
- `operation` label values: "fetch_resources", "config_load"
- `broker_type` label values: "gcp-pubsub", "rabbitmq"
- Expose metrics endpoint on port 8080 at `/metrics`