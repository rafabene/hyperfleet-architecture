# HyperFleet Logging Specification

This document defines the standard logging approach for all HyperFleet components (API, Sentinel, Adapters).

---

## Overview

### Goals

- **Consistency**: All components configure logging the same way
- **Traceability**: Distributed tracing via common fields (`trace_id`, `event_id`)
- **Observability**: Structured logs that integrate with log aggregation systems

### Non-Goals

- Creating a shared logging library
- Mandating a specific logging framework

---

## Configuration

All components MUST support configuration via **command-line flags** and **environment variables**. Configuration files are optional.

| Option | Flag | Environment Variable | Default | Description |
|--------|------|---------------------|---------|-------------|
| Log Level | `--log-level` | `LOG_LEVEL` | `info` | Minimum level: `debug`, `info`, `warn`, `error` |
| Log Format | `--log-format` | `LOG_FORMAT` | `text` | Output format: `text` or `json` |
| Log Output | `--log-output` | `LOG_OUTPUT` | `stdout` | Destination: `stdout`, `stderr`, or file path |

**Precedence** (highest to lowest): flags → environment variables → config file → defaults

For production, use `LOG_FORMAT=json` for better log aggregation.

---

## Log Levels

Ordered by severity (lowest to highest):

| Level | Description | Examples |
|-------|-------------|----------|
| `debug` | Detailed debugging | Variable values, event payloads |
| `info` | Operational information | Startup, successful operations |
| `warn` | Warning conditions | Retry attempts, slow operations |
| `error` | Error conditions | Failures, invalid configuration |

When `LOG_LEVEL` is set, only messages at that level or higher are output.

---

## Log Fields

### Required Fields

All log entries MUST include:

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | RFC3339 | When created (UTC) |
| `level` | string | Log level |
| `message` | string | Human-readable message |
| `component` | string | Component name (`api`, `sentinel`, `adapter-validation`) |
| `version` | string | Component version |
| `hostname` | string | Pod name or hostname |

### Correlation Fields

Include when available for distributed tracing:

| Field | Scope | Description |
|-------|-------|-------------|
| `trace_id` | Distributed | OpenTelemetry trace ID (propagated across services) |
| `span_id` | Distributed | Current span identifier |
| `request_id` | Single service | HTTP request identifier (API only) |
| `event_id` | Event-driven | CloudEvents ID |

### Resource Fields

Include when processing a resource:

| Field | Description |
|-------|-------------|
| `cluster_id` | Cluster identifier |
| `resource_type` | Resource type (`clusters`, `nodepools`) |
| `resource_id` | Resource identifier |

### Error Fields

Include when logging errors:

| Field | Type | Description |
|-------|------|-------------|
| `error` | string | Error message |
| `stack_trace` | array | Stack trace (only for unexpected errors or debug level) |

---

## Log Formats

### Text Format (Default)

For local development:

```text
{timestamp} {LEVEL} [{component}] [{hostname}] {message} {key=value}...
```

```text
2025-01-15T10:30:00.123Z INFO  [sentinel] [sentinel-7d4b8c6f5] Publishing event cluster_id=cls-123
2025-01-15T10:30:05.456Z ERROR [sentinel] [sentinel-7d4b8c6f5] Failed to publish error="connection refused"
2025-01-15T10:30:05.456Z ERROR [sentinel] [sentinel-7d4b8c6f5] Unexpected error error="nil pointer"
    main.processCluster() processor.go:89
    main.reconcileLoop() loop.go:45
```

### JSON Format (Production)

For log aggregation:

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "message": "Publishing event",
  "component": "sentinel",
  "version": "v1.2.3",
  "hostname": "sentinel-7d4b8c6f5",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "event_id": "evt-abc-123",
  "cluster_id": "cls-123"
}
```

**Error with stack trace:**

```json
{
  "timestamp": "2025-01-15T10:30:05.456Z",
  "level": "error",
  "message": "Unexpected error",
  "component": "sentinel",
  "version": "v1.2.3",
  "hostname": "sentinel-7d4b8c6f5",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "cluster_id": "cls-123",
  "error": "nil pointer dereference",
  "stack_trace": [
    "main.processCluster() processor.go:89",
    "main.reconcileLoop() loop.go:45"
  ]
}
```

---

## Component Guidelines

Additional fields per component:

### API

| Field | Description |
|-------|-------------|
| `method` | HTTP method |
| `path` | Request path |
| `status_code` | Response status |
| `duration_ms` | Request duration |

### Sentinel

| Field | Description |
|-------|-------------|
| `decision_reason` | Why event was published (`generation_mismatch`, `max_age_expired`) |
| `topic` | Pub/Sub topic name |
| `shard` | Shard identifier (if sharding enabled) |

### Adapters

| Field | Description |
|-------|-------------|
| `adapter` | Adapter type name |
| `job_name` | Kubernetes Job name |
| `job_result` | Outcome (`success`, `failed`, `skipped`) |
| `observed_generation` | Resource generation processed |
| `subscription` | Pub/Sub subscription name |

---

## Distributed Tracing

Components MUST propagate OpenTelemetry trace context:

1. **Incoming**: Extract `trace_id`/`span_id` from W3C headers (`traceparent`)
2. **Outgoing**: Inject trace headers when calling other services
3. **Events**: Include `trace_id` in CloudEvents
4. **Logs**: Always include `trace_id` when available

This enables log correlation across: API → Sentinel → Broker → Adapters

---

## Sensitive Data

The following MUST be redacted or omitted:

- API tokens and credentials
- Passwords and secrets
- Cloud provider access keys
- Personal identifiable information (PII)
