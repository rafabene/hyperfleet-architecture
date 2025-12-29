# HyperFleet Generated Code Policy

## *Policy for managing generated code in HyperFleet repositories*

## Metadata
- **Date:** 2025-12-26
- **Authors:** Rafael Benevides
- **Status:** Active
- **Related Jira(s):** [HYPERFLEET-303](https://issues.redhat.com/browse/HYPERFLEET-303)
- **Related Docs:** [Makefile Conventions](makefile-conventions.md)

---

## 1. Overview

This document establishes the policy for handling generated code in HyperFleet repositories.

### What is Generated Code?

Generated code refers to any files automatically created by tools from source specifications. These files should never be manually edited.

**Examples in HyperFleet:**

| File Pattern | Generator | Source |
|--------------|-----------|--------|
| `model_*.go` | oapi-codegen | OpenAPI specification (`openapi.yaml`) |
| `*_mock.go` | mockgen | Go interfaces |
| `*.pb.go` | protoc | Protocol Buffer definitions (`.proto`) |

**Key Decision:** Generated code **MUST NOT** be committed to Git repositories. Instead, it is generated on-demand during the build process.

---

## 2. Rationale

### Why not commit generated code?

| Problem | Impact |
|---------|--------|
| Merge conflicts | Generated files frequently conflict when multiple developers modify source specs |
| Sync issues | Generated code can become out-of-sync with source specifications |
| Repository bloat | Large generated files increase clone times and repository size |
| Accidental edits | Developers may accidentally modify generated files instead of source specs |
| Unclear ownership | Confusion about whether specs or generated code is the source of truth |

### Benefits of on-demand generation

| Benefit | Description |
|---------|-------------|
| Single source of truth | Specifications are the authoritative source |
| Always in sync | Generated code is always derived from current specs |
| Smaller repositories | Reduced clone times and disk usage |
| Clear workflow | Developers know to modify specs, not generated files |
| Industry alignment | Follows best practices for generated artifacts |

---

## 3. Affected Repositories and File Patterns

### Repositories

| Repository | Generated Code Location | Source Specification | Status |
|------------|------------------------|---------------------|--------|
| `hyperfleet-api` | `pkg/api/openapi/`, `*_mock.go` | OpenAPI specification | ✅ Compliant |
| `hyperfleet-sentinel` | `pkg/api/openapi/`, `openapi/openapi.yaml` | OpenAPI specification | ✅ Compliant |

**Note:** `hyperfleet-adapter`, `hyperfleet-broker`, and adapter repositories do not currently have generated code.

### File Patterns to Exclude

Each repository should add appropriate patterns to `.gitignore`:

**hyperfleet-api:**
```gitignore
# Generated OpenAPI code
/pkg/api/openapi/
/data/generated/

# Generated mock files
*_mock.go
```

**hyperfleet-sentinel:**
```gitignore
# Generated OpenAPI client
pkg/api/openapi/

# Downloaded OpenAPI spec
openapi/openapi.yaml
```

---

## 4. Developer Workflow

### Prerequisites

Developers **MUST** have the following tools installed:

- **Podman** or **Docker** - Required for running code generation in containers
- **Make** - Required for running build targets

### First-time Setup

```bash
# Clone the repository
git clone https://github.com/openshift-hyperfleet/<repo-name>
cd <repo-name>

# Generate code before building or testing
make generate

# Build the project
make build

# Run tests
make test
```

### Daily Workflow

1. **Pull latest changes:** `git pull`
2. **Regenerate code:** `make generate` (or rely on `make build`/`make test` dependencies)
3. **Make changes:** Edit source specifications (not generated files)
4. **Regenerate:** `make generate`
5. **Build and test:** `make build && make test`
6. **Commit:** Only commit source specification changes

### Important Notes

- **Never edit generated files directly** - Changes will be overwritten
- **Always run `make generate` after pulling** - Ensures generated code matches current specs
- **Generation is idempotent** - Safe to run multiple times

---

## 5. Makefile Requirements

All HyperFleet repositories with generated code **MUST** follow the [Makefile Conventions](makefile-conventions.md) with these additional requirements:

### Required Target

Repositories with generated code **MUST** implement a `generate` target:

```makefile
.PHONY: generate
generate: ## Generate code from specifications
    # Repository-specific generation commands
```

### Target Dependencies

The `generate` target **MUST** be a prerequisite for `build` and `test` targets:

```makefile
build: generate ## Build the binary
test: generate ## Run unit tests
test-integration: generate ## Run integration tests
```

### Generation Characteristics

| Requirement | Description |
|-------------|-------------|
| Idempotent | Running multiple times produces identical output |
| Deterministic | Same input specifications produce same output |
| Containerized | Uses Podman/Docker for reproducibility |

---

## 6. CI/CD Pipeline Requirements

All CI/CD pipelines **MUST**:

1. Run `make generate` as the **first step** (or rely on `make build` dependency)
2. Fail the build if generation fails
3. Optionally verify no generated files are committed

### Optional: Verify No Generated Files Committed

Add a CI job to ensure generated files are not accidentally committed:

```bash
make generate
if git diff --name-only | grep -E "(model_.*\.go|\.pb\.go|_gen\.go)"; then
  echo "ERROR: Generated files were committed to the repository"
  echo "Please remove them and add patterns to .gitignore"
  exit 1
fi
```

---

## 7. References

- [Makefile Conventions](makefile-conventions.md)
- [HYPERFLEET-303](https://issues.redhat.com/browse/HYPERFLEET-303)
- [oapi-codegen](https://github.com/deepmap/oapi-codegen)
- [Protocol Buffers](https://protobuf.dev/)
