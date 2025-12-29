# HyperFleet Makefile Conventions

This guide provides a standardized set of Makefile targets and conventions applicable to all HyperFleet repositories.

---

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Standard Targets](#standard-targets)
4. [Flag Conventions](#flag-conventions)
5. [References](#references)

---

## Overview

This document defines standard Makefile targets and conventions for all HyperFleet repositories. Following these conventions reduces cognitive load when switching between repos, enables consistent CI/CD pipelines, and improves developer onboarding.

### Scope

This standard applies to:
- All HyperFleet service repositories
- All adapter repositories (adapter-pullsecret, adapter-dns, etc.)
- Infrastructure and tooling repositories

### Problem Statement

Currently, different HyperFleet repositories use different target names for similar operations:
- Some use `make compile`, others use `make build` or `make binary`
- Binary output locations vary (some use `bin/`, others use project root)
- CI pipelines have inconsistent invocations across repos
- Engineers must read each Makefile to understand available commands

This inconsistency creates unnecessary friction and slows down development.

---

## Goals

1. **Reduce cognitive load** - Same commands work across all repos
2. **Enable automation** - CI/CD pipelines can use standard targets
3. **Improve onboarding** - New developers learn once, apply everywhere
4. **Increase reliability** - Consistent behavior reduces errors
5. **Support tooling** - Claude plugin and scripts can assume standard targets

---

## Standard Targets

### Required Targets

All HyperFleet repositories **MUST** implement these targets:

| Target | Description | Expected Behavior | Example Output |
|--------|-------------|-------------------|----------------|
| `help` | Display available targets | Print formatted list of targets with descriptions | Help text to stdout |
| `build` | Build all binaries | Compile source code to executable binaries | Outputs to `bin/` directory |
| `test` | Run unit tests | Execute all unit tests with coverage | Coverage report + pass/fail |
| `lint` | Run linters | Execute configured linters (golangci-lint, yamllint, etc.) | Linting violations or success |
| `clean` | Remove build artifacts | Delete all generated files (binaries, coverage, build cache) | Empty `bin/`, `build/` directories |

**Example invocation:**
```bash
make help           # See all available targets
make build          # Compile binaries
make test           # Run tests
make lint           # Run linters
make clean          # Clean up
```

### Optional Targets

Repositories **MAY** implement these targets if applicable:

| Target | Description | When to Use | Example |
|--------|-------------|-------------|---------|
| `generate` | Generate code from specifications | If repo uses code generation (OpenAPI, Protocol Buffers, etc.) | Generate Go models from OpenAPI specs |
| `test-all` | Run all tests and checks | Comprehensive pre-commit validation | Runs test + lint + test-integration + test-helm |
| `test-integration` | Run integration tests | If repo has integration tests requiring external dependencies | Tests against real GCP/K8s |
| `test-helm` | Run all Helm validation | If repo contains Helm charts | Runs helm-lint + helm-template |
| `image` | Build container image | If repo produces a container image | `make image IMAGE_TAG=v1.0.0` |
| `image-push` | Push container image to registry | If repo publishes to container registry | `make image-push` |
| `helm-lint` | Lint Helm charts | If repo contains Helm charts | Validate chart syntax |
| `helm-template` | Template Helm charts | If repo contains Helm charts | Render templates locally |
| `deploy` | Deploy to environment | If repo has deployment logic | Deploy to dev/staging |
| `run` | Run the application locally | For services that can run standalone | Start local server |

**Example invocation:**
```bash
make generate                   # Generate code from specs
make test-all                   # Run all tests and checks (recommended before commit)
make test-integration           # Run integration tests
make test-helm                  # Run all Helm validation (lint + template)
make image IMAGE_TAG=v1.0.0    # Build container image
make image-push                 # Push to registry
```

### Target Naming Rules

- Use **lowercase** with hyphens for multi-word targets (e.g., `test-integration`, not `integrationTest`)
- Use **verbs** for action targets (e.g., `build`, `test`, `clean`)
- Keep names **short** but descriptive (max 20 characters)
- Avoid abbreviations (use `test-integration`, not `int-test`)

---

### Binary Output Location

**Rule:** All compiled binaries **MUST** be output to the `bin/` directory.

```makefile
# Good - output to bin/ directory
# Example: go build -o bin/pull-secret ./cmd/pull-secret
build:
	go build -o bin/app-name ./cmd/app-name

# Bad - DO NOT output to project root
build:
	go build -o app-name ./cmd/app-name
```

### Temporary Files

| File Type | Location | Description |
|-----------|----------|-------------|
| Binaries | `bin/` | All compiled executables |
| Build artifacts | `build/` | Temporary build files, cache |
| Test coverage | `coverage.txt`, `coverage.html` | Coverage reports |
| Container images | N/A (tagged only) | Not stored locally after build |

**Important:** All temporary files should be in `.gitignore`:

```gitignore
# Build outputs
bin/
build/

# Test coverage
coverage.txt
coverage.html
coverage.out
*.coverprofile
```

---

## Flag Conventions

### Standard Variables

All Makefiles **SHOULD** support these environment variables:

| Variable | Default | Description | Example Usage |
|----------|---------|-------------|---------------|
| `VERBOSE` | `0` | Enable verbose output (1=enabled, 0=disabled) | `make build VERBOSE=1` |
| `IMAGE_TAG` | `latest` | Container image tag | `make image IMAGE_TAG=v1.0.0` |
| `IMAGE_REGISTRY` | (repo-specific) | Container registry URL | `make image IMAGE_REGISTRY=quay.io/hyperfleet` |
| `GOOS` | (host OS) | Target operating system for build | `make build GOOS=linux` |
| `GOARCH` | (host arch) | Target architecture for build | `make build GOARCH=amd64` |
| `CGO_ENABLED` | `0` | Enable/disable CGO | `make build CGO_ENABLED=1` |

### Boolean Flag Convention

Use `1` for true, `0` for false:

```makefile
VERBOSE ?= 0

ifeq ($(VERBOSE),1)
    GO_FLAGS += -v
    Q =
else
    Q = @
endif

build:
	$(Q)echo "Building..."
	$(Q)go build $(GO_FLAGS) -o bin/app-name ./cmd/app-name
```

### Variable Definition Pattern

Always use `?=` for variables that can be overridden:

```makefile
# Good - allows override
IMAGE_TAG ?= latest
VERBOSE ?= 0

# Bad - cannot override
IMAGE_TAG = latest
```

---

## References

### External Resources

- [GNU Make Manual](https://www.gnu.org/software/make/manual/)
- [Makefile Best Practices](https://tech.davis-hansson.com/p/make/)
- [Self-Documented Makefiles](https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html)

