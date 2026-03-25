# HyperFleet MVP — Bill of Artifacts

**Status**: Active
**Owner**: HyperFleet Team
**Last Updated**: 2026-03-25

---

## Executive Summary

This document provides a comprehensive inventory of all artifacts delivered as part of the HyperFleet MVP milestone. HyperFleet is a cloud-agnostic, event-driven platform for automated cluster lifecycle management built to provision and manage hosted OpenShift clusters at scale.

This bill of artifacts serves as both a single reference for external stakeholders (leadership, partner teams, new joiners) and a baseline for tracking work beyond MVP.

---

## Table of Contents

- [1. Core Platform Services](#1-core-platform-services)
- [2. Supporting Services and Tools](#2-supporting-services-and-tools)
- [3. API Contracts and Specifications](#3-api-contracts-and-specifications)
- [4. Infrastructure and Deployment](#4-infrastructure-and-deployment)
- [5. Testing](#5-testing)
- [6. CI/CD and Release Infrastructure](#6-cicd-and-release-infrastructure)
- [7. Architecture Documentation](#7-architecture-documentation)
- [8. Integration Points](#8-integration-points)
- [9. Key Architectural Decisions](#9-key-architectural-decisions)
- [10. Delivery Milestones](#10-delivery-milestones)
- [11. Repository Summary](#11-repository-summary)

---

## 1. Core Platform Services

The platform follows an event-driven architecture: the API stores data, the Sentinel makes orchestration decisions, the Broker distributes events, and Adapters execute cloud-specific operations.

### 1.1 HyperFleet API

| | |
|---|---|
| **Repository** | [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) |
| **Language** | Go 1.24+ |
| **State** | Active, production-ready |

Stateless REST API serving as the pure CRUD data layer for cluster lifecycle management. Intentionally contains no business logic or event creation — separation of concerns is a core design principle.

- REST operations covering Cluster and NodePool resources
- PostgreSQL database with GORM ORM, generation-aware status aggregation
- Kubernetes-style conditions (`Ready`, `Available`) aggregated from adapter reports
- Label-based search and filtering via TSL (Tree Search Language)
- Plugin-based resource registration, embedded OpenAPI spec and Swagger UI
- Helm chart with HPA (HorizontalPodAutoscaler), PDB (PodDisruptionBudget), ServiceMonitor, optional PostgreSQL or external DB mode

### 1.2 HyperFleet Sentinel

| | |
|---|---|
| **Repository** | [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) |
| **Language** | Go 1.25 |
| **State** | Active, production-ready |

Kubernetes-native reconciliation trigger service implementing a poll-decide-publish loop. The orchestration brain of HyperFleet.

- CEL-based configurable decision engine with generation-based (immediate on spec change), time-based (max age for periodic reconciliation), and new-resource detection logic
- Publishes CloudEvents v1 with CEL (Common Expression Language) for both decision logic and dynamic payload building, plus W3C trace propagation
- Horizontal sharding via config-driven label selectors — no leader election needed
- Broker abstraction: GCP Pub/Sub, RabbitMQ, and Stub backends via the `hyperfleet-broker` library
- Exponential backoff retry with transient/permanent error classification
- Helm chart with PDB, PodMonitoring (GKE/GMP), ServiceMonitor, PrometheusRule
- Pre-built Grafana dashboard and 8 alert rules

### 1.3 HyperFleet Adapter Framework

| | |
|---|---|
| **Repository** | [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) |
| **Language** | Go 1.25 |
| **State** | Active, production-ready |

Configuration-driven framework for executing provisioning tasks. Single binary, infinite configurations — you write YAML, not Go code.

- Four-phase execution pipeline: Param Extraction, Precondition Evaluation (structured conditions or CEL), Resource Application, Status Reporting
- Two-config architecture: AdapterConfig (infrastructure) + AdapterTaskConfig (business logic)
- Dual transport backends: Kubernetes direct (client-go) and Maestro/OCM (Open Cluster Management) ManifestWork (gRPC + HTTP to Maestro server for remote cluster delivery)
- Generation-based idempotent reconciliation (CREATE / UPDATE / SKIP / RECREATE)
- Dry-run mode for local development without infrastructure dependencies
- Helm chart v2.0.0 with auto-generated RBAC, HPA, PDB, ServiceMonitor

### 1.4 HyperFleet Broker

| | |
|---|---|
| **Repository** | [hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker) |
| **Language** | Go 1.25 |
| **State** | Active, stable |

Shared Go library providing a unified pub/sub messaging abstraction with built-in CloudEvents support. Imported by Sentinel and Adapter — not a standalone service.

- Two backends: RabbitMQ (Watermill AMQP) and Google Cloud Pub/Sub (Watermill Google Cloud)
- CloudEvents v1.0 automatic wrapping/unwrapping, dead letter topic support
- Two messaging patterns: load balancing (shared subscription) and fanout (separate subscriptions)
- Publisher health checks for readiness probes, Prometheus metrics, configurable worker pools

---

## 2. Supporting Services and Tools

| Repository | Description | Language | State |
|-----------|-------------|----------|-------|
| [maestro-cli](https://github.com/openshift-hyperfleet/maestro-cli) | CLI for ManifestWork lifecycle management through Maestro (apply, delete, get, list, watch). Dual-protocol: gRPC + HTTP. | Go 1.25 | Active |
| [hyperfleet-credential-provider](https://github.com/openshift-hyperfleet/hyperfleet-credential-provider) | Multi-cloud Kubernetes ExecCredential plugin for GCP/GKE, AWS/EKS, Azure/AKS authentication. Pure Go, no cloud CLI dependencies. | Go 1.24 | Active |
| [registry-credentials-service](https://github.com/openshift-hyperfleet/registry-credentials-service) | REST API for container registry credentials management. Built on Red Hat T-Rex framework with PostgreSQL, OIDC/JWT auth. | Go 1.24 | Active |

---

## 3. API Contracts and Specifications

### 3.1 HyperFleet API Spec (TypeSpec)

| | |
|---|---|
| **Repository** | [hyperfleet-api-spec](https://github.com/openshift-hyperfleet/hyperfleet-api-spec) |
| **Language** | TypeSpec |
| **Version** | 1.0.4 |

TypeSpec definitions generating OpenAPI 3.0 specifications (with optional OpenAPI 2.0 conversion for legacy tooling), published as GitHub Release artifacts. Supports multi-cloud provider variants via alias-based type switching (`aliases-core.tsp`, `aliases-gcp.tsp`). Key models: Cluster, NodePool, Status, Error (RFC 9457). Interactive API docs via GitHub Pages.

> **Note:** The production OpenAPI contract used by code generation lives in [hyperfleet-api/openapi/openapi.yaml](https://github.com/openshift-hyperfleet/hyperfleet-api/blob/main/openapi/openapi.yaml).

### 3.2 CloudEvents Contract

All inter-service events use CloudEvents v1.0 with anemic payloads (resource ID, kind, generation only) and W3C `traceparent` for distributed tracing. Formal schema defined in [`hyperfleet/components/broker/asyncapi.yaml`](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/components/broker/asyncapi.yaml).

- `ReconcileCluster` — event type: `com.redhat.hyperfleet.cluster.reconcile.v1`, payload: `ObjectReference` + `generation`
- `ReconcileNodePool` — event type: `com.redhat.hyperfleet.nodepool.reconcile.v1`, payload: `ObjectReference` + `generation` + `owner_references`

---

## 4. Infrastructure and Deployment

### 4.1 HyperFleet Infra

| | |
|---|---|
| **Repository** | [hyperfleet-infra](https://github.com/openshift-hyperfleet/hyperfleet-infra) |
| **State** | Active |

Infrastructure as Code for HyperFleet environments. Makefile-driven provisioning (Terraform) and deployment (Helm).

**Terraform Modules:** GKE cluster (`terraform/modules/cluster/gke/`), Google Pub/Sub (`terraform/modules/pubsub/`), shared VPC infrastructure (`terraform/shared/`). Multi-cloud stubs (EKS, AKS) present for post-MVP expansion.

**Helm Umbrella Charts (7):** `api`, `adapter1`, `adapter2`, `adapter3`, `sentinel-clusters`, `sentinel-nodepools`, `maestro` — each wrapping the upstream component chart with environment-specific values.

**Additional:** RabbitMQ dev manifest, broker Helm values generator script, full lifecycle Makefile targets (`install-all`, `uninstall-all`, `status`).

### 4.2 Per-Component Helm Charts

Each core service ships its own Helm chart: hyperfleet-api (v1.0.0), hyperfleet-sentinel (v1.0.0), hyperfleet-adapter (v2.0.0). All follow security best practices: non-root user, read-only rootfs, capabilities dropped, seccomp enabled. Container images use multi-stage Docker builds with Red Hat UBI9 base images, published to `quay.io/openshift-hyperfleet/`.

---

## 5. Testing

### 5.1 E2E Testing Framework

| | |
|---|---|
| **Repository** | [hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e) |
| **Language** | Go 1.25 |
| **State** | Active |

Black-box E2E testing framework for validating Critical User Journeys (CUJ). Ginkgo-based with ephemeral resource management, parallel execution, label-based filtering, JUnit XML reports, and container image support for CI.

**Test Suites:**

| Suite | What it validates |
|-------|-------------------|
| Cluster Creation | End-to-end cluster lifecycle: creation, initial conditions, adapter execution, final Ready state |
| Cluster Concurrent Creation | 5 simultaneous cluster creations reach Ready state without resource conflicts |
| Cluster Adapter Failure | Adapter precondition failures are reflected in cluster top-level status |
| NodePool Creation | End-to-end nodepool lifecycle: creation under a parent cluster, adapter execution, Ready state |
| NodePool Concurrent Creation | 3 simultaneous nodepools under the same cluster reach Ready state with isolated resources |
| Adapter Failover | Adapter framework detects invalid Kubernetes resources and reports failures with clear error messages |
| Adapter with Maestro Transport | Full Maestro transport path: ManifestWork creation, Maestro agent applies to target cluster, adapter reports status back via discovery |

### 5.2 Per-Component Testing

All core services use testcontainers-go for integration testing and golangci-lint for code quality.

| Component | Unit Tests | Integration Tests | Helm Tests | Notable |
|-----------|-----------|-------------------|------------|---------|
| hyperfleet-api | Handlers, services, DAO, auth, middleware, presenters | Testcontainers + PostgreSQL: adapter status, clusters CRUD, node pools, API contract, search field mapping | 8+ value combinations (external DB, autoscaling, PDB, ServiceMonitor, auth) | Mock factories for clusters/nodepools, gotestsum runner |
| hyperfleet-sentinel | Config, decision engine, payload builder, metrics, health | Testcontainers + real message brokers | 10+ scenarios (PDB, RabbitMQ, Pub/Sub, PodMonitoring, PrometheusRule) | Mock HyperFleet API server for load testing, profiling tools |
| hyperfleet-adapter | Config loader, CEL criteria, executor pipeline, manifest generation, dry-run engine | Dual strategy: envtest (unprivileged, CI-friendly) and K3s (faster); Maestro client TLS tests | 9+ scenarios (broker, API config, PDB, autoscaling, probes) | ~65-75% coverage target, ~30-40s for 10 suites (24 test cases) |
| hyperfleet-broker | CloudEvents conversion, config, health checks, metrics | Testcontainers + RabbitMQ and Pub/Sub emulator | — | Performance benchmarks, leak detection tests |

---

## 6. CI/CD and Release Infrastructure

| | |
|---|---|
| **Release Process** | [hyperfleet-release-process.md](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/docs/hyperfleet-release-process.md) |

- **Prow**: Primary CI system for core services (presubmit and postsubmit jobs, externally managed job definitions)
- **Konflux/RHTAP**: CI/CD for registry-credentials-service (Tekton-based pipelines)
- **Release process**: Hybrid cadence, independent component versioning, release branches with forward-port workflow, multi-gate readiness criteria

---

## 7. Architecture Documentation

All documentation lives in [openshift-hyperfleet/architecture](https://github.com/openshift-hyperfleet/architecture):

| Category | Location | Contents |
|----------|----------|----------|
| System Architecture | `hyperfleet/architecture/` | architecture summary, component diagrams, data flows |
| Component Designs | `hyperfleet/components/` | Sentinel, Adapter, API Service, Broker, Claude Code Plugin |
| Implementation Guides | `hyperfleet/docs/` | release process, Prow CI/CD, versioning, sentinel pulses, status guide, repo creation, documentation, WIF spike |
| Engineering Standards | `hyperfleet/standards/` | prescriptive standards: logging, metrics, tracing, error model, health endpoints, graceful shutdown, commits, directory structure, configuration, container images, dependency pinning, generated code, Helm charts, linting, Makefiles |
| MVP Documents | `hyperfleet/mvp/` | MVP scope, working agreement |
| Deployment Guides | `hyperfleet/deployment/GKE/` | GKE quickstart, cluster creation/deletion scripts |
| Templates | `hyperfleet/docs/templates/` | CHANGELOG, CONTRIBUTING, README templates |

---

## 8. Integration Points

| Consumer Team | Status | Integration Details |
|---------------|--------|---------------------|
| **GCP** | Primary MVP target | GKE cluster provisioning (Terraform), Cloud Pub/Sub as production message broker, Cloud DNS for cluster provisioning, Compute/IAM/CRM API validation, Workload Identity Federation for keyless auth |
| **ROSA / AWS** | Post-MVP | Multi-cloud foundation in place (credential provider supports AWS/EKS, API spec alias system supports provider variants). ROSA/AWS adapter implementation planned for post-MVP |

---

## 9. Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **v1 -> v2 simplification** | Removed Outbox Pattern, centralized business logic in Sentinel. Fewer components, lower latency. |
| **Config-driven adapters** | Single binary with YAML config. Build once, reuse for every adapter and cloud provider. |
| **Broker abstraction** | Cloud-agnostic messaging (GCP Pub/Sub / RabbitMQ). Switch providers without code changes. |
| **Anemic events** | CloudEvents carry only resource ID, kind, generation. Adapters fetch full state from API. |
| **Independent component versioning** | Each service has its own semver. Validated releases = compatibility-tested version combinations. |
| **TypeSpec for API contracts** | TypeSpec -> OpenAPI pipeline with multi-provider variant support via alias system. |
| **Generation-aware reconciliation** | Spec changes increment generation. Enables idempotent adapter execution and accurate readiness. |
| **Kubernetes-style conditions** | `Ready`/`Available` conditions aggregated from adapters, not a single phase field. |
| **CEL expression engine** | Used in Sentinel (decision logic and event payloads) and Adapter (preconditions, post-actions). Safe, sandboxed evaluation. |
| **Dual transport backends** | Kubernetes direct + Maestro/OCM ManifestWork. Local and remote cluster operations. |

---

## 10. Delivery Milestones

### MVP Phases (per [mvp-scope.md](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/mvp/mvp-scope.md))

| Phase | Focus | Status |
|-------|-------|--------|
| **Milestone 1: Foundation** | API service, database, message broker, adapter framework, CI pipeline | Complete |
| **Milestone 2: Core Implementation** | Sentinels, cluster/nodepool adapters, observability, E2E framework | Complete |
| **Milestone 3: Handover Readiness** | CI/CD pipeline, documentation, security, load testing, handover docs | In Progress |
| **Milestone 4: Post-Handover** | Full CRUD, additional cloud providers, BU-specific features | Planned |

---

## 11. Repository Summary

| # | Repository | Type | Language |
|---|-----------|------|----------|
| 1 | [hyperfleet-api](https://github.com/openshift-hyperfleet/hyperfleet-api) | Core Service | Go |
| 2 | [hyperfleet-sentinel](https://github.com/openshift-hyperfleet/hyperfleet-sentinel) | Core Service | Go |
| 3 | [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) | Core Service | Go |
| 4 | [hyperfleet-broker](https://github.com/openshift-hyperfleet/hyperfleet-broker) | Shared Library | Go |
| 5 | [maestro-cli](https://github.com/openshift-hyperfleet/maestro-cli) | CLI Tool | Go |
| 6 | [hyperfleet-credential-provider](https://github.com/openshift-hyperfleet/hyperfleet-credential-provider) | CLI Tool | Go |
| 7 | [registry-credentials-service](https://github.com/openshift-hyperfleet/registry-credentials-service) | Service | Go |
| 8 | [hyperfleet-api-spec](https://github.com/openshift-hyperfleet/hyperfleet-api-spec) | API Contract | TypeSpec |
| 9 | [hyperfleet-infra](https://github.com/openshift-hyperfleet/hyperfleet-infra) | Infrastructure | Terraform/Helm |
| 10 | [hyperfleet-e2e](https://github.com/openshift-hyperfleet/hyperfleet-e2e) | Testing | Go |
| 11 | [architecture](https://github.com/openshift-hyperfleet/architecture) | Documentation | Markdown |
