# HyperFleet Makefile Conventions

This guide provides a standardized set of Makefile targets and conventions applicable to all HyperFleet repositories.

---

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Standard Targets](#standard-targets)
4. [Directory Structure](#directory-structure)
5. [Flag Conventions](#flag-conventions)
6. [Help Target Format](#help-target-format)
7. [Compliance Checklist](#compliance-checklist)
8. [References](#references)

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
| `integration-test` | Run integration tests | If repo has integration tests requiring external dependencies | Tests against real GCP/K8s |
| `image` | Build container image | If repo produces a container image | `make image IMAGE_TAG=v1.0.0` |
| `image-push` | Push container image to registry | If repo publishes to container registry | `make image-push` |
| `helm-lint` | Lint Helm charts | If repo contains Helm charts | Validate chart syntax |
| `helm-template` | Template Helm charts | If repo contains Helm charts | Render templates locally |
| `deploy` | Deploy to environment | If repo has deployment logic | Deploy to dev/staging |
| `run` | Run the application locally | For services that can run standalone | Start local server |

**Example invocation:**
```bash
make integration-test           # Run integration tests
make image IMAGE_TAG=v1.0.0    # Build container image
make image-push                 # Push to registry
make helm-lint                  # Validate Helm charts
```

### Target Naming Rules

- Use **lowercase** with hyphens for multi-word targets (e.g., `integration-test`, not `integrationTest`)
- Use **verbs** for action targets (e.g., `build`, `test`, `clean`)
- Keep names **short** but descriptive (max 20 characters)
- Avoid abbreviations (use `integration-test`, not `int-test`)

---

## Directory Structure

### Standard Layout

All HyperFleet repositories should follow this directory structure:

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
├── pkg/                    # Shared libraries
├── k8s/                    # Kubernetes manifests
├── helm/                   # Helm charts (if applicable)
├── Makefile                # Standard Makefile
├── Dockerfile              # Container definition
└── README.md
```

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

**Important:** Both `bin/` and `build/` should be in `.gitignore`.

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

## Help Target Format

### Required Implementation

All repositories **MUST** implement a `help` target as the default goal:

```makefile
.DEFAULT_GOAL := help

# Project-specific variables
PROJECT_NAME := my-service
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

##@ General

help: ## Display this help
	@echo ""
	@echo "$(PROJECT_NAME) - Available targets"
	@echo "Version: $(VERSION)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo ""
.PHONY: help

##@ Build

build: ## Build the binary
	@echo "Building $(PROJECT_NAME)..."
	go build -o bin/app-name ./cmd/app-name

##@ Test

test: ## Run unit tests
	@echo "Running unit tests..."
	go test -v -race -coverprofile=coverage.txt ./...

lint: ## Run linters
	@echo "Running linters..."
	golangci-lint run

##@ Cleanup

clean: ## Remove build artifacts
	@echo "Cleaning build artifacts..."
	rm -rf bin/ build/ coverage.txt coverage.html
```

### Target Documentation

**All targets MUST have inline documentation** using `##`:

```makefile
# Good - documented
build: ## Build the binary
	go build -o bin/app-name ./cmd/app-name

# Bad - no documentation
build:
	go build -o bin/app-name ./cmd/app-name
```

### Section Headers

Use `##@` to create sections in the help output:

```makefile
##@ Build
build: ## Build the binary

##@ Test
test: ## Run unit tests
lint: ## Run linters

##@ Cleanup
clean: ## Remove build artifacts
```

**Example help output:**
```
my-service - Available targets
Version: v1.0.0

Usage:
  make <target>

Build
  build                 Build the binary

Test
  test                  Run unit tests
  lint                  Run linters

Cleanup
  clean                 Remove build artifacts
```

---

## Compliance Checklist

Use this checklist to verify your repository follows the standard:

### Required Targets
- [ ] `make help` implemented and set as default goal
- [ ] `make build` compiles all binaries
- [ ] `make test` runs unit tests
- [ ] `make lint` runs linters
- [ ] `make clean` removes all build artifacts

### Directory Structure
- [ ] Binaries output to `bin/` directory
- [ ] Temporary files go to `build/` directory
- [ ] Both `bin/` and `build/` in `.gitignore`

### Documentation
- [ ] All targets have `##` inline documentation
- [ ] Help target displays formatted output
- [ ] README updated with standard targets

### Variables
- [ ] `VERBOSE` flag supported
- [ ] `IMAGE_TAG` supported (if building images)
- [ ] `IMAGE_REGISTRY` supported (if building images)
- [ ] All variables use `?=` for override capability

### Code Quality
- [ ] All targets have `.PHONY` declarations
- [ ] No hard-coded paths (use variables)
- [ ] Errors fail the build (use `set -e` in shell commands)

### Example Compliance Check

```bash
# Run these commands to verify compliance
make help                          # Should display all targets
make build                         # Should create bin/ directory
ls bin/                            # Should contain binaries
make test                          # Should run tests
make lint                          # Should run linters
make clean && ls bin/              # Should fail (directory removed)
make build VERBOSE=1               # Should show verbose output
```

---

## Examples

### Comparison: Before vs After

#### Before (Inconsistent)

**Repository A:**
```bash
make compile          # Builds binary to project root
make check            # Runs tests
make docker-build     # Builds image
```

**Repository B:**
```bash
make binary           # Builds binary to bin/
make unit-test        # Runs tests
make image            # Builds image
```

**Repository C:**
```bash
make build            # Builds binary to build/output/
make test-all         # Runs tests
make container        # Builds image
```

#### After (Consistent)

**All Repositories:**
```bash
make help             # Display available targets
make build            # Builds binary to bin/
make test             # Runs tests
make lint             # Runs linters
make clean            # Removes build artifacts
make image            # Builds container image (if applicable)
```

---

## References

### External Resources

- [GNU Make Manual](https://www.gnu.org/software/make/manual/)
- [Makefile Best Practices](https://tech.davis-hansson.com/p/make/)
- [Self-Documented Makefiles](https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html)

