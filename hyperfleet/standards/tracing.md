# HyperFleet Tracing and Telemetry Standard

This document defines the standard approach for distributed tracing across all HyperFleet components (API, Sentinel, Adapters).

---

## Overview

### Goals

- **Visibility**: End-to-end request tracing across API, Sentinel, and Adapters
- **Correlation**: Link traces with logs and metrics for unified observability
- **Consistency**: All components instrument tracing the same way
- **Debuggability**: Enable efficient troubleshooting of distributed operations

### Non-Goals

- Observability infrastructure setup (backend, storage, visualization)
- Retroactive instrumentation of existing code (separate tickets)
- Creating a shared tracing library

---

## OpenTelemetry Adoption

HyperFleet adopts [OpenTelemetry](https://opentelemetry.io/) as the standard for distributed tracing.

### Why OpenTelemetry

- **Vendor-neutral**: Works with any observability backend (Jaeger, Tempo, Cloud Trace, etc.)
- **Industry standard**: CNCF project with broad adoption
- **Unified API**: Single API for traces, metrics, and logs
- **Auto-instrumentation**: Libraries available for common frameworks
- **W3C Trace Context**: Native support for standard trace propagation

### SDK Requirements

All HyperFleet components MUST use the OpenTelemetry Go SDK:

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/sdk/trace"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
)
```

---

## Configuration

All components MUST support tracing configuration via **environment variables**. Command-line flags are optional.

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `OTEL_SERVICE_NAME` | Component name | Service name for traces |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `localhost:4317` | OTLP gRPC endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | Protocol: `grpc` or `http/protobuf` |
| `OTEL_TRACES_SAMPLER` | `parentbased_traceidratio` | Sampler type |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | Sampler argument (ratio for ratio-based samplers) |
| `OTEL_PROPAGATORS` | `tracecontext,baggage` | Context propagators |
| `OTEL_RESOURCE_ATTRIBUTES` | - | Additional resource attributes |
| `TRACING_ENABLED` | `true` | Enable/disable tracing |

### Service Names

Each component MUST set `OTEL_SERVICE_NAME` to its component name:

| Component | Service Name |
|-----------|--------------|
| API | `hyperfleet-api` |
| Sentinel | `hyperfleet-sentinel` |
| Validation Adapter | `hyperfleet-adapter-validation` |
| Provisioning Adapter | `hyperfleet-adapter-provisioning` |

### Resource Attributes

Components SHOULD include these resource attributes via `OTEL_RESOURCE_ATTRIBUTES`:

```bash
OTEL_RESOURCE_ATTRIBUTES="service.version=v1.2.3,deployment.environment=production,k8s.namespace.name=hyperfleet"
```

---

## Trace Context Propagation

HyperFleet uses [W3C Trace Context](https://www.w3.org/TR/trace-context/) for trace propagation across service boundaries.

### HTTP Requests

Extract and inject trace context from/to HTTP headers:

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

// Server: Extract context from incoming request
ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))

// Client: Inject context into outgoing request
otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
```

### CloudEvents (Pub/Sub)

Trace context MUST be propagated via CloudEvents extension attributes:

| Extension | Description |
|-----------|-------------|
| `traceparent` | W3C Trace Context traceparent header |
| `tracestate` | W3C Trace Context tracestate header (optional) |

```go
// Publisher: Add trace context to CloudEvent
event := cloudevents.NewEvent()
event.SetExtension("traceparent", traceparentFromContext(ctx))

// Subscriber: Extract trace context from CloudEvent
traceparent, _ := event.Extensions()["traceparent"].(string)
ctx := contextFromTraceparent(ctx, traceparent)
```

### Propagation Flow

HyperFleet has two main trace flows:

1. **Reconciliation**: Sentinel → API → Sentinel → Pub/Sub → Adapter (asynchronous)
2. **Client requests**: Client → API (synchronous HTTP)

```mermaid
flowchart TB
    subgraph Client Flow
        C[Client] -->|traceparent<br/>HTTP| API1[API]
        API1 --> L1[Logs<br/>trace_id]
    end

    subgraph Reconciliation Flow
        S[Sentinel] -->|traceparent<br/>HTTP| API2[API]
        API2 --> L2[Logs<br/>trace_id]
        API2 -->|response| S
        S --> L3[Logs<br/>trace_id]
        S -->|traceparent<br/>CloudEvent| PS[Pub/Sub]
        PS --> AD[Adapter]
        AD --> L4[Logs<br/>trace_id]
        AD -->|traceparent<br/>HTTP| API3[API]
        API3 --> L5[Logs<br/>trace_id]
    end
```

> **Note:** Sentinel initiates traces during polling cycles. The trace context propagates through CloudEvents to Adapters, which include it when updating status back to the API.

---

## Required Spans

Components MUST create spans for the following operations.

### Span Naming Convention

Follow [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/) for span names:

| Span Type | Naming Pattern | Example |
|-----------|----------------|---------|
| HTTP Server | `{method} {route}` | `GET /clusters/{id}` |
| HTTP Client | `{method}` | `GET` |
| Database | `{operation} {table}` | `SELECT clusters` |
| Messaging | `{destination} {operation}` | `hyperfleet-clusters publish` |
| Custom | `{component}.{operation}` | `sentinel.evaluate` |

> **Note:** Use attributes (not span names) for high-cardinality values like IDs, hostnames, or dynamic paths.

### All Components

| Operation | Span Name | Required |
|-----------|-----------|----------|
| HTTP request handling | `{method} {route}` | When exposing HTTP |
| External HTTP calls | `{method}` | When making HTTP calls |
| Database operations | `{operation} {table}` | When using database |

### API

| Operation | Span Name Pattern | Example |
|-----------|-------------------|---------|
| Request handling | `{method} {route}` | `GET /clusters/{id}` |
| Database query | `{operation} {table}` | `SELECT clusters` |
| Authentication | `api.{operation}` | `api.validate_token` |

### Sentinel

| Operation | Span Name Pattern | Example |
|-----------|-------------------|---------|
| Poll cycle | `sentinel.{operation}` | `sentinel.poll` |
| Decision evaluation | `sentinel.{operation}` | `sentinel.evaluate` |
| Event publish | `{destination} {operation}` | `hyperfleet-clusters publish` |
| API call | `{method}` | `GET` |

### Adapters

| Operation | Span Name Pattern | Example |
|-----------|-------------------|---------|
| Event receive | `{destination} {operation}` | `hyperfleet-clusters receive` |
| Event process | `adapter.{operation}` | `adapter.process` |
| Cloud provider call | `{method}` | `POST` |
| Status update | `{method}` | `PATCH` |

---

## Standard Span Attributes

### Semantic Conventions

Follow [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/) for common attributes.

### HTTP Spans

| Attribute | Type | Description |
|-----------|------|-------------|
| `http.request.method` | string | HTTP method |
| `url.path` | string | Request path (sanitized) |
| `http.response.status_code` | int | Response status code |
| `server.address` | string | Server hostname |
| `http.route` | string | Route template (e.g., `/clusters/{id}`) |

### Database Spans

| Attribute | Type | Description |
|-----------|------|-------------|
| `db.system` | string | Database type (`postgresql`, `redis`) |
| `db.operation.name` | string | Operation (`SELECT`, `INSERT`, etc.) |
| `db.collection.name` | string | Table/collection name |

### Messaging Spans (Pub/Sub)

| Attribute | Type | Description |
|-----------|------|-------------|
| `messaging.system` | string | Messaging system (`gcp_pubsub`) |
| `messaging.operation.type` | string | Operation (`publish`, `receive`, `process`) |
| `messaging.destination.name` | string | Topic or subscription name |
| `messaging.message.id` | string | Message ID |

### HyperFleet-Specific Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `hyperfleet.cluster_id` | string | Cluster identifier |
| `hyperfleet.resource_type` | string | Resource type (`clusters`, `nodepools`) |
| `hyperfleet.resource_id` | string | Resource identifier |
| `hyperfleet.adapter` | string | Adapter type name |
| `hyperfleet.decision_reason` | string | Sentinel decision reason |

### Attribute Best Practices

**DO:**
- Use semantic conventions where applicable
- Include resource identifiers for debugging
- Sanitize paths to avoid high cardinality

**DON'T:**
- Include sensitive data (tokens, passwords, PII)
- Use high-cardinality values as span names
- Include large payloads in attributes

---

## Sampling Strategy

### Head-Based vs Tail-Based Sampling

| Approach | Decision Point | Pros | Cons |
|----------|---------------|------|------|
| **Head-based** | At trace start | Simple, low overhead, no data buffering | Cannot sample based on outcome (errors, latency) |
| **Tail-based** | After trace completes | Can sample interesting traces (errors, slow) | Requires buffering, higher resource usage |

**HyperFleet uses head-based sampling** for simplicity and lower operational overhead. Tail-based sampling requires additional infrastructure (OpenTelemetry Collector with tail sampling processor) and is recommended only when error/latency-based sampling is critical.

### Default: Parent-Based Trace ID Ratio

HyperFleet uses `parentbased_traceidratio` as the default sampler:

- If parent span exists: Follow parent's sampling decision
- If no parent: Sample based on trace ID ratio

### Environment-Specific Sampling Rates

| Environment | Sampling Rate | Rationale |
|-------------|---------------|-----------|
| Development | `1.0` (100%) | Full visibility for debugging |
| Staging | `0.1` (10%) | Balance between visibility and cost |
| Production | `0.01` (1%) | Cost-effective for high-traffic systems |

### Configuration Example

```bash
# Development
OTEL_TRACES_SAMPLER=always_on

# Production
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.01
```

### Always Sample

Certain operations SHOULD always be sampled regardless of the base rate:

- Error responses (status >= 500)
- Slow operations (duration > SLO threshold)
- Operations on specific resources (for debugging)

Implementation using a custom sampler or head-based rules is recommended for these cases.

---

## Exporter Configuration

### OTLP Exporter (Default)

All components MUST support OTLP as the primary export format:

```go
exporter, err := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint(os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")),
    otlptracegrpc.WithInsecure(), // For local development
)
```

### Kubernetes Deployment

In Kubernetes, configure the OTLP endpoint to point to an OpenTelemetry Collector:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "otel-collector.observability.svc:4317"
  - name: OTEL_SERVICE_NAME
    value: "hyperfleet-sentinel"
  - name: OTEL_TRACES_SAMPLER
    value: "parentbased_traceidratio"
  - name: OTEL_TRACES_SAMPLER_ARG
    value: "0.01"
```

### Local Development

For local development, use a local collector or stdout exporter:

```bash
# Use stdout for debugging
OTEL_TRACES_EXPORTER=console

# Or use a local Jaeger instance
OTEL_EXPORTER_OTLP_ENDPOINT=localhost:4317
```

---

## Integration with Logging

Traces MUST be correlated with logs via `trace_id` and `span_id` fields.

### Adding Trace Context to Logs

```go
import (
    "log/slog"
    "go.opentelemetry.io/otel/trace"
)

func logWithTrace(ctx context.Context, logger *slog.Logger, msg string, args ...any) {
    spanCtx := trace.SpanContextFromContext(ctx)
    if spanCtx.HasTraceID() {
        args = append(args,
            "trace_id", spanCtx.TraceID().String(),
            "span_id", spanCtx.SpanID().String(),
        )
    }
    logger.InfoContext(ctx, msg, args...)
}
```

### Log Output Example

```json
{
  "timestamp": "2025-01-15T10:30:00.123Z",
  "level": "info",
  "message": "Processing cluster event",
  "component": "adapter-validation",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "cluster_id": "cls-123"
}
```

For detailed logging requirements, see the [Logging Specification](./logging-specification.md).

---

## Error Handling in Spans

### Recording Errors

When an error occurs, record it on the span:

```go
import (
    "go.opentelemetry.io/otel/codes"
)

span.RecordError(err)
span.SetStatus(codes.Error, err.Error())
```

### Error Attributes

Include relevant context when recording errors:

```go
span.RecordError(err,
    trace.WithAttributes(
        attribute.String("error.type", "validation_error"),
        attribute.String("cluster_id", clusterID),
    ),
)
```

---

## Span Lifecycle Best Practices

### Starting and Ending Spans

```go
ctx, span := tracer.Start(ctx, "operation.name",
    trace.WithSpanKind(trace.SpanKindServer),
)
defer span.End()

// Do work...

if err != nil {
    span.RecordError(err)
    span.SetStatus(codes.Error, "operation failed")
    return err
}

span.SetStatus(codes.Ok, "")
```

### Context Propagation

Always pass context through the call chain:

```go
// Good: Context is propagated
func ProcessEvent(ctx context.Context, event Event) error {
    ctx, span := tracer.Start(ctx, "adapter.process")
    defer span.End()

    return updateStatus(ctx, event.ClusterID)
}

// Bad: Context is not propagated, trace is broken
func ProcessEvent(ctx context.Context, event Event) error {
    _, span := tracer.Start(ctx, "adapter.process")
    defer span.End()

    return updateStatus(context.Background(), event.ClusterID) // Trace broken!
}
```

---

## References

- [OpenTelemetry Go SDK](https://github.com/open-telemetry/opentelemetry-go)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [OpenTelemetry Environment Variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [HyperFleet Logging Specification](./logging-specification.md)
- [HyperFleet Metrics Standard](./metrics.md)
