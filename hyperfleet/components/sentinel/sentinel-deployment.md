# Sentinel Service Deployment

This document provides Kubernetes deployment manifests and configuration examples for the HyperFleet Sentinel service.

For the main Sentinel architecture and design documentation, see [sentinel.md](./sentinel.md).

---

## Kubernetes Deployment (Single Replica, No Leader Election)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-sentinel
  namespace: hyperfleet-system
  labels:
    app: cluster-sentinel
    app.kubernetes.io/name: hyperfleet-sentinel
    sentinel.hyperfleet.io/resource-type: clusters
spec:
  replicas: 1  # Single replica per resource selector
  selector:
    matchLabels:
      app: cluster-sentinel
  template:
    metadata:
      labels:
        app: cluster-sentinel
    spec:
      serviceAccountName: hyperfleet-sentinel
      terminationGracePeriodSeconds: 30
      containers:
      - name: sentinel
        image: quay.io/hyperfleet/sentinel:v1.0.0
        imagePullPolicy: IfNotPresent
        command:
        - /sentinel
        args:
        - --config=/etc/sentinel/config.yaml  # Path to YAML config file
        - --metrics-bind-address=:9090
        - --health-probe-bind-address=:8080
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
        - containerPort: 9090
          name: metrics
          protocol: TCP
        - containerPort: 8080
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

---

## ServiceAccount and RBAC

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
    max_age_not_ready: 10s
    max_age_ready: 30m
    resource_selector:
      - label: region
        value: us-east

    hyperfleet_api:
      endpoint: http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080
      timeout: 30s

    message_data:
      resource_id: .id
      resource_type: .kind
      generation: .generation
      region: .metadata.labels.region
  gcp-project-id: "hyperfleet-prod"
---
# Broker configuration (Sentinel-specific)
# Choose one based on your environment:

# Google Cloud Pub/Sub:
apiVersion: v1
kind: ConfigMap
metadata:
  name: hyperfleet-sentinel-broker
  namespace: hyperfleet-system
data:
  BROKER_TYPE: "pubsub"
  BROKER_PROJECT_ID: "hyperfleet-prod"

---
# RabbitMQ:
apiVersion: v1
kind: ConfigMap
metadata:
  name: hyperfleet-sentinel-broker
  namespace: hyperfleet-system
data:
  BROKER_TYPE: "rabbitmq"
  BROKER_HOST: "rabbitmq.hyperfleet-system.svc.cluster.local"
  BROKER_PORT: "5672"
  BROKER_VHOST: "/"
  BROKER_EXCHANGE: "hyperfleet-events"
  BROKER_EXCHANGE_TYPE: "fanout"

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

**Broker Configuration**: Sentinel uses a separate `hyperfleet-sentinel-broker` ConfigMap. Adapters have their own broker ConfigMap (`hyperfleet-adapter-broker`) with different fields:
- **Sentinel** (publisher): Uses BROKER_TOPIC, BROKER_EXCHANGE to publish events
- **Adapters** (consumers): Use BROKER_SUBSCRIPTION_ID, BROKER_QUEUE_NAME to consume events
- **Common fields** (BROKER_TYPE, BROKER_PROJECT_ID, BROKER_HOST) are duplicated in both ConfigMaps for simplicity

> **Note:** For topic naming conventions and multi-tenant isolation strategies, see [Naming Strategy](./sentinel-naming-strategy.md).

---

## Metrics and Observability

### Prometheus Metrics

The Sentinel service must expose the following Prometheus metrics:

| Metric Name | Type | Labels | Description |
|-------------|------|--------|-------------|
| `hyperfleet_sentinel_pending_resources` | Gauge | `component`, `version`, `resource_selector`, `resource_type` | Number of resources matching this selector |
| `hyperfleet_sentinel_events_published_total` | Counter | `component`, `version`, `resource_selector`, `resource_type` | Total number of events published to broker |
| `hyperfleet_sentinel_resources_skipped_total` | Counter | `component`, `version`, `resource_selector`, `resource_type`, `ready_state` | Total number of resources skipped due to backoff |
| `hyperfleet_sentinel_poll_duration_seconds` | Histogram | `component`, `version`, `resource_selector`, `resource_type` | Time spent in each polling cycle |
| `hyperfleet_sentinel_api_errors_total` | Counter | `component`, `version`, `resource_selector`, `resource_type`, `operation` | Total API errors by operation (fetch_resources, config_load) |
| `hyperfleet_sentinel_broker_errors_total` | Counter | `component`, `version`, `resource_selector`, `resource_type`, `broker_type` | Total broker publishing errors |
| `hyperfleet_sentinel_config_loads_total` | Counter | `component`, `version`, `resource_selector`, `resource_type` | Total configuration loads at startup |

**Implementation Requirements**:
- Use standard Prometheus Go client library
- All metrics must include `component` and `version` labels (see [Metrics Standard](../../standards/metrics.md))
- All metrics must include `resource_selector` label (from resource_selector string)
- All metrics must include `resource_type` label (from configuration resource_type field)
- `ready_state` label values: "ready" or "not_ready"
- `operation` label values: "fetch_resources", "config_load"
- `broker_type` label values: "pubsub", "rabbitmq"
- Expose metrics endpoint on port 9090 at `/metrics`

For complete health and readiness endpoint standards, see [Health Endpoints Specification](../../standards/health-endpoints.md).

For cross-component metrics conventions, see [HyperFleet Metrics Standard](../../standards/metrics.md).
