# HyperFleet Directory Structure Standard

This document defines the standard directory structure for all HyperFleet repositories to ensure consistency, improve developer experience, and enable automation.

---

## Table of Contents

1. [Overview](#overview)
2. [Standard Directory Layout](#standard-directory-layout)
3. [Directory Descriptions](#directory-descriptions)
4. [Temporary Files](#temporary-files)
5. [Gitignore Requirements](#gitignore-requirements)
6. [References](#references)

---

## Overview

### Problem Statement

Currently, HyperFleet repositories have inconsistent directory structures:
- Binaries are output to different locations (some to `bin/`, others to project root)
- Source code organization varies between repositories
- Kubernetes manifests and Helm charts are in different locations
- Build artifacts are scattered across repositories
- `.gitignore` files have different coverage

This inconsistency creates friction when:
- Developers switch between repositories
- CI/CD pipelines need to locate artifacts
- Tooling assumes standard paths
- New developers onboard to the project

### Goals

1. **Reduce cognitive load** - Same structure across all repos
2. **Enable automation** - Tools and scripts can assume standard paths
3. **Improve onboarding** - Learn the structure once, apply everywhere
4. **Increase reliability** - Consistent behavior reduces errors
5. **Simplify CI/CD** - Standard artifact locations

### Scope

This standard applies to:
- All HyperFleet service repositories
- All adapter repositories (adapter-pullsecret, adapter-dns, etc.)
- Infrastructure and tooling repositories

---

## Standard Directory Layout

All HyperFleet repositories **MUST** follow this directory structure:

```
repo-root/
├── bin/                    # Compiled binaries (gitignored)
│   └── app-name            # Compiled binary (e.g., pull-secret, dns-adapter)
├── build/                  # Temporary build artifacts (gitignored)
│   ├── cache/              # Build cache
│   └── tmp/                # Temporary files
├── cmd/                    # Main application(s)
│   └── app-name/           # Application-specific directory (e.g., pull-secret/)
│       ├── main.go         # Main executable
│       └── jobs/           # Job implementations (if applicable)
│           └── job.go
├── pkg/                    # Shared libraries (reusable across HyperFleet services)
│   ├── logger/             # Structured logging
│   ├── errors/             # Error handling utilities
│   └── utils/              # Common utility functions
├── internal/               # Private application code (service-specific)
│   ├── api/                # API client implementations
│   ├── config/             # Configuration loading
│   ├── handlers/           # HTTP handlers
│   ├── services/           # Business logic
│   └── models/             # Data models
├── configs/                # Configuration file templates (if applicable)
│   ├── config.yaml.example # Example configuration
│   └── defaults/           # Default configurations
├── openapi/                # OpenAPI/Swagger specifications (if applicable)
│   ├── api.yaml            # OpenAPI 3.0 specification
│   └── v1/                 # Versioned API specs
│       └── swagger.json
├── kustomize/              # Kustomize manifests (if applicable)
│   ├── base/               # Base Kustomize configuration
│   ├── overlays/           # Environment-specific overlays
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   └── crds/               # Custom Resource Definitions (if applicable)
├── charts/                 # Helm charts (if applicable)
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── docs/                   # Documentation (see documentation standard for details)
│   ├── metrics.md          # Prometheus metric definitions (services only)
│   ├── alerts.md           # Alert rules and monitoring (services only)
│   ├── runbook.md          # Operational runbook (services only)
│   ├── configuration.md   # Configuration reference (services only)
│   ├── development/        # Development setup and workflows
│   ├── deployment/         # Deployment guides and procedures
│   ├── troubleshooting/    # Debugging and troubleshooting guides
│   └── examples/           # Usage examples and tutorials
├── scripts/                # Helper scripts
│   ├── setup.sh
│   └── deploy.sh
├── test/                   # Integration and E2E tests
│   ├── integration/
│   └── e2e/
├── .github/                # GitHub configuration
│   └── workflows/          # GitHub Actions
├── Makefile                # Standard Makefile (see makefile-conventions.md)
├── Dockerfile              # Container definition (see container-image-standard.md)
├── .dockerignore           # Docker build context exclusions (must exclude .git/)
├── .gitignore              # Git ignore rules
├── go.mod                  # Go module definition (for Go projects)
├── go.sum                  # Go module checksums
└── README.md               # Project documentation
```

---

## Directory Descriptions

### Required Directories

| Directory | Purpose | Required | Notes |
|-----------|---------|----------|-------|
| `bin/` | Compiled binaries | Yes | Must be in `.gitignore` |
| `cmd/` | Main application entry points | Yes | One subdirectory per executable |
| `pkg/` | Shared libraries | Yes | Code designed for reuse across HyperFleet services (logger, errors, utils) |
| `internal/` | Private application code | Yes | Service-specific implementation (handlers, services, models, config). Go compiler prevents external imports. |
| `Makefile` | Build automation | Yes | See [makefile-conventions.md](makefile-conventions.md) |
| `.dockerignore` | Docker build context exclusions | Yes (if `Dockerfile` exists) | Must exclude `.git/` at minimum. See [container-image-standard.md](container-image-standard.md) |
| `README.md` | Project documentation | Yes | Clear overview and setup instructions |

### Optional Directories

| Directory | Purpose | When to Use | Notes |
|-----------|---------|-------------|-------|
| `build/` | Temporary build artifacts | If build generates temporary files | Must be in `.gitignore` |
| `configs/` | Configuration file templates | If repo requires default configs or examples | Example configs, defaults. Committed to Git |
| `openapi/` | OpenAPI/Swagger specifications | If repo defines APIs via OpenAPI specs | YAML/JSON files, committed to Git |
| `kustomize/` | Kustomize manifests | If repo uses Kustomize for deployment | Base + overlays structure |
| `charts/` | Helm charts | If repo uses Helm for deployment | Follows Helm community convention |
| `docs/` | Documentation (operational, development, deployment) | If README.md is not sufficient for the repo's documentation needs | Service repos: see [documentation standard](../docs/documentation.md) for required operational files. Non-service repos: use for development guides, architecture notes, etc. |
| `scripts/` | Helper scripts | If repo has automation scripts | Shell, Python, etc. |
| `test/` | Integration/E2E tests | If unit tests are in `*_test.go` files | Separate from unit tests |

---

## Temporary Files

All temporary files and build artifacts must be in designated locations:

| File Type | Location | Description | In .gitignore |
|-----------|----------|-------------|---------------|
| Binaries | `bin/` | All compiled executables | Yes |
| Build artifacts | `build/` | Temporary build files, cache | Yes |
| Test coverage | Root (project root) | `coverage.txt`, `coverage.html`, `coverage.out` | Yes |
| Generated code | Varies | `*.gen.go`, `*_generated.go` | Yes (if using on-demand generation) |
| Dependencies | Root | `vendor/` (if using vendoring) | Yes |
| Container images | N/A | Tagged only, not stored locally | N/A |

---

## Gitignore Requirements

### Mandatory Rules

All HyperFleet repositories **MUST** include these patterns in `.gitignore`:

```gitignore
# Binaries
bin/
*.exe
*.exe~
*.dll
*.so
*.dylib

# Build artifacts
build/
*.o
*.a

# Test coverage
coverage.txt
coverage.html
coverage.out
*.coverprofile

# Go workspace files
go.work
go.work.sum

# IDE and editor files
.vscode/
.idea/
*.swp
*.swo
*~
.DS_Store

# Environment files
.env
.env.local
*.local

# Dependency directories (if vendoring)
vendor/
```


---

## References

### Related Documents
- [Makefile Conventions](makefile-conventions.md) - Standard Makefile targets
- [Container Image Standard](container-image-standard.md) - Dockerfile conventions, base images, and labels

### External Resources
- [Go Project Layout](https://github.com/golang-standards/project-layout)
- [Kubernetes Documentation](https://kubernetes.io/docs/concepts/)
- [Kustomize Documentation](https://kustomize.io/)
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)

