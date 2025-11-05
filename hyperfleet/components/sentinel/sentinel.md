## What & Why

**What**

Implement a Kubernetes Operator called "HyperFleet Sentinel" that continuously polls the HyperFleet API for resources (clusters, node pools, etc.) and publishes reconciliation events directly to the message broker to trigger adapter processing. The Sentinel acts as the "watchful guardian" of the HyperFleet system with simple, configurable backoff intervals. Multiple Sentinel deployments can be configured via CRD to handle different shards of resources for horizontal scalability.

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

- SentinelConfig CRD defined and installed
- Kubernetes Operator deployed as single replica per shard
- Operator reads configuration from SentinelConfig CR
- Polls HyperFleet API for resources matching shard criteria
- Uses `status.lastTransitionTime` from adapter status updates for backoff calculation
- Creates CloudEvents for resources based on simple decision logic
- Publishes events directly to message broker (GCP Pub/Sub or RabbitMQ)
- Configurable backoff intervals (not-ready vs ready)
- Sharding support via label selectors in CRD
- Metrics exposed for monitoring (reconciliation rate, event publishing, errors)
- Integration tests verify decision logic and backoff behavior with adapter status updates
- Graceful shutdown and error handling implemented
- Multiple operators can run simultaneously with different shards

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
    Start([Start Reconcile Loop]) --> ReadConfig[Read SentinelConfig CRD<br/>- backoffNotReady: 10s<br/>- backoffReady: 30m<br/>- shardSelector: region=us-east<br/>- broker configuration]

    ReadConfig --> FetchClusters[Fetch Clusters with Shard Filter<br/>GET /api/hyperfleet/v1/clusters<br/>?labels=region=us-east]

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
    NextCluster -->|No| Requeue[Requeue After Poll Interval<br/>5 seconds]

    Requeue --> Start

    style Start fill:#e1f5e1
    style PublishEvent fill:#ffe1e1
    style Skip fill:#e1e5ff
    style ReadConfig fill:#fff4e1
    style FetchClusters fill:#fff4e1
```

**Multiple Operator Deployments (Sharding)**:

```mermaid
graph LR
    subgraph US-East["Cluster Sentinel (us-east)"]
        direction TB
        Config1[SentinelConfig:<br/>cluster-sentinel-us-east]
        Shard1[Shard Selector:<br/>region=us-east]
        Config1 --> Shard1
    end

    subgraph US-West["Cluster Sentinel (us-west)"]
        direction TB
        Config2[SentinelConfig:<br/>cluster-sentinel-us-west]
        Shard2[Shard Selector:<br/>region=us-west]
        Config2 --> Shard2
    end

    subgraph EU-West["Cluster Sentinel (eu-west)"]
        direction TB
        Config3[SentinelConfig:<br/>cluster-sentinel-eu-west]
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

**Configuration** (via SentinelConfig CRD):
```yaml
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: SentinelConfig
metadata:
  name: cluster-sentinel-us-east
  namespace: hyperfleet-system
spec:
  # Resource type this sentinel watches
  resourceType: clusters

  # Backoff when resource status != "Ready"
  backoffNotReady: 10s

  # Backoff when resource status == "Ready"
  backoffReady: 30m

  # Shard selector - only process resources matching these labels
  shardSelector:
    matchLabels:
      region: us-east

  # HyperFleet API configuration
  hyperfleetAPI:
    url: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
    timeout: 10s

  # Message broker configuration
  broker:
    type: gcp-pubsub  # or "rabbitmq"
    topic: hyperfleet-events
    projectID: hyperfleet-prod  # For GCP Pub/Sub
    # Alternative for RabbitMQ:
    # url: amqp://guest:guest@rabbitmq:5672/
    # exchange: hyperfleet-events

  # Poll interval for fetching resources
  pollInterval: 5s
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
1. Each Sentinel deployment references ONE SentinelConfig CR
2. SentinelConfig defines `resourceType` (clusters, nodepools, etc.) and `shardSelector` (Kubernetes label selector)
3. Sentinel only fetches resources matching the resource type and shard selector
4. Multiple Sentinels can run simultaneously with non-overlapping selectors
5. Each Sentinel publishes to the same broker topic/exchange (fan-out to adapters)

**Example Sharding Strategy**:

```yaml
# Deployment 1: US East clusters
---
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: SentinelConfig
metadata:
  name: cluster-sentinel-us-east
spec:
  resourceType: clusters
  shardSelector:
    matchLabels:
      region: us-east
  backoffNotReady: 10s
  backoffReady: 30m
  broker:
    type: gcp-pubsub
    topic: hyperfleet-events
    projectID: hyperfleet-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel-us-east
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: sentinel
        args:
        - --config=cluster-sentinel-us-east

---
# Deployment 2: US West clusters
---
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: SentinelConfig
metadata:
  name: cluster-sentinel-us-west
spec:
  resourceType: clusters
  shardSelector:
    matchLabels:
      region: us-west
  backoffNotReady: 15s  # Different config!
  backoffReady: 1h
  broker:
    type: gcp-pubsub
    topic: hyperfleet-events
    projectID: hyperfleet-prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel-us-west
spec:
  replicas: 1

---
# Future: NodePool Sentinel
---
apiVersion: hyperfleet.redhat.com/v1alpha1
kind: SentinelConfig
metadata:
  name: nodepool-sentinel
spec:
  resourceType: nodepools  # Different resource type!
  shardSelector: {}  # Watch all node pools
  backoffNotReady: 5s
  backoffReady: 10m
  broker:
    type: gcp-pubsub
    topic: hyperfleet-events
    projectID: hyperfleet-prod
```

---

## Operator Components

### 1. SentinelConfig CRD

**Purpose**: Configuration and sharding for HyperFleet Sentinels

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: sentinelconfigs.hyperfleet.redhat.com
spec:
  group: hyperfleet.redhat.com
  names:
    kind: SentinelConfig
    listKind: SentinelConfigList
    plural: sentinelconfigs
    singular: sentinelconfig
    shortNames:
    - sc
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required:
            - resourceType
            - hyperfleetAPI
            - broker
            properties:
              resourceType:
                type: string
                description: "HyperFleet resource type to watch (clusters, nodepools, etc.)"
                enum:
                - clusters
                - nodepools
              backoffNotReady:
                type: string
                default: "10s"
                description: "Backoff interval for resources NOT in Ready state"
              backoffReady:
                type: string
                default: "30m"
                description: "Backoff interval for resources in Ready state"
              shardSelector:
                type: object
                description: "Label selector for resource sharding"
                properties:
                  matchLabels:
                    type: object
                    additionalProperties:
                      type: string
                  matchExpressions:
                    type: array
                    items:
                      type: object
                      properties:
                        key:
                          type: string
                        operator:
                          type: string
                        values:
                          type: array
                          items:
                            type: string
              hyperfleetAPI:
                type: object
                required:
                - url
                properties:
                  url:
                    type: string
                    description: "HyperFleet API base URL"
                  timeout:
                    type: string
                    default: "10s"
              broker:
                type: object
                required:
                - type
                - topic
                properties:
                  type:
                    type: string
                    enum:
                    - gcp-pubsub
                    - rabbitmq
                    description: "Message broker type"
                  topic:
                    type: string
                    description: "Topic/Exchange name for publishing events"
                  projectID:
                    type: string
                    description: "GCP Project ID (required for gcp-pubsub)"
                  url:
                    type: string
                    description: "Broker URL (required for rabbitmq)"
                  exchange:
                    type: string
                    description: "Exchange name (optional for rabbitmq, defaults to topic)"
              pollInterval:
                type: string
                default: "5s"
                description: "How often to poll HyperFleet API"
```

### 2. Config Loader

**Responsibility**: Watch SentinelConfig CR and load configuration

**Key Functions**:
- `Load(ctx)` - Fetch SentinelConfig CR from Kubernetes API
- `BuildLabelSelector(cfg)` - Convert `shardSelector` to Kubernetes label selector

**Implementation Requirements**:
- Watch SentinelConfig CR for changes
- Parse duration strings (backoffNotReady, backoffReady, pollInterval, timeout)
- Parse resourceType field to determine which HyperFleet resources to fetch
- Parse broker configuration (type, topic, credentials)
- Convert label selector from CR spec to `labels.Selector` type
- Handle missing or invalid configuration gracefully
- Return structured configuration object for use by reconciler

### 3. Resource Watcher

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

### 4. Decision Engine (Simplified)

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

### 5. Message Publisher

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

### 6. Main Reconciler

**Responsibility**: Orchestrate reconciliation loop with configuration reloading

**Key Functions**:
- `Reconcile(ctx, req)` - Main reconciliation loop
- `SetupWithManager(mgr)` - Register controller with manager

**Reconciliation Steps**:
1. **Load Configuration**:
   - Fetch SentinelConfig CR from Kubernetes
   - Parse backoff intervals, shard selector, broker config, and resource type
   - Update DecisionEngine if config changed
   - Initialize MessagePublisher with broker config
   - Log configuration updates

2. **Fetch Resources**:
   - Build label selector from shard configuration
   - Determine resource endpoint from resourceType (e.g., /clusters, /nodepools)
   - Call ResourceWatcher.FetchResources(ctx, resourceType, selector)
   - Log resource count and shard information
   - Record metric for pending resources

3. **Evaluate Each Resource**:
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

4. **Requeue**:
   - Return `Result{RequeueAfter: cfg.PollInterval}`
   - Default: 5 seconds

**Setup**:
- Watch SentinelConfig CR for changes
- Trigger reconciliation when CR is created/updated
- Use controller-runtime framework

**Error Handling**:
- On config load failure: requeue after 30 seconds
- On resource fetch failure: requeue after poll interval
- On event publishing failure: log error, record metric, continue to next resource

---

## Operator Deployment

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
        - --config=cluster-sentinel-default  # Name of SentinelConfig CR
        - --namespace=hyperfleet-system
        - --metrics-bind-address=:8080
        - --health-probe-bind-address=:8081
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /var/secrets/google/key.json  # For GCP Pub/Sub
        volumeMounts:
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
# Role for reading SentinelConfig CR
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hyperfleet-sentinel
  namespace: hyperfleet-system
rules:
- apiGroups:
  - hyperfleet.redhat.com
  resources:
  - sentinelconfigs
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - hyperfleet.redhat.com
  resources:
  - sentinelconfigs/status
  verbs:
  - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hyperfleet-sentinel
  namespace: hyperfleet-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: hyperfleet-sentinel
subjects:
- kind: ServiceAccount
  name: hyperfleet-sentinel
  namespace: hyperfleet-system
```

**Note**: No leader election RBAC needed since we run single replica per deployment. Sharding provides horizontal scaling instead.

---

## Metrics and Observability

### Prometheus Metrics

The Sentinel must expose the following Prometheus metrics:

| Metric Name | Type | Labels | Description |
|-------------|------|--------|-------------|
| `hyperfleet_sentinel_pending_resources` | Gauge | `shard`, `resource_type` | Number of resources in this shard |
| `hyperfleet_sentinel_events_published_total` | Counter | `shard`, `resource_type` | Total number of events published to broker |
| `hyperfleet_sentinel_resources_skipped_total` | Counter | `shard`, `resource_type`, `ready_state` | Total number of resources skipped due to backoff |
| `hyperfleet_sentinel_reconcile_duration_seconds` | Histogram | `shard`, `resource_type` | Time spent in reconciliation loop |
| `hyperfleet_sentinel_api_errors_total` | Counter | `shard`, `resource_type`, `operation` | Total API errors by operation (fetch_resources, config_load) |
| `hyperfleet_sentinel_broker_errors_total` | Counter | `shard`, `resource_type`, `broker_type` | Total broker publishing errors |
| `hyperfleet_sentinel_config_reloads_total` | Counter | `shard`, `resource_type` | Total SentinelConfig reloads |

**Implementation Requirements**:
- Use controller-runtime metrics registry
- All metrics must include `shard` label (from label selector string)
- All metrics must include `resource_type` label (from SentinelConfig resourceType field)
- `ready_state` label values: "ready" or "not_ready"
- `operation` label values: "fetch_resources", "config_load"
- `broker_type` label values: "gcp-pubsub", "rabbitmq"
- Expose metrics endpoint on port 8080 at `/metrics`