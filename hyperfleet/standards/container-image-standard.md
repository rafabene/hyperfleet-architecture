# HyperFleet Container Image Standard

This document defines the standard conventions for Dockerfiles, base images, and container build practices across all HyperFleet service repositories.

---

## Table of Contents

1. [Overview](#overview)
2. [Base Images](#base-images)
3. [Multi-Stage Build Pattern](#multi-stage-build-pattern)
4. [Non-Root Users](#non-root-users)
5. [Go Build Parameters](#go-build-parameters)
6. [Container Labels](#container-labels)
7. [.dockerignore](#dockerignore)
8. [Reference Dockerfile](#reference-dockerfile)
9. [References](#references)

---

## Overview

### Problem Statement

HyperFleet repositories currently have inconsistent Dockerfile conventions:
- Different base images are used across services (Debian, Alpine, UBI)
- Some images run as root, others don't
- Build flags and version embedding vary
- Container labels are inconsistent or missing
- Some repositories are missing `.dockerignore`, causing build issues with `-buildvcs`

### Goals

1. **Consistent base images** - All services use the same approved builder and runtime images
2. **Security by default** - Non-root users in all stages
3. **Reproducible builds** - Standard version embedding and build flags
4. **Compliance-ready** - FIPS considerations documented and supported
5. **Efficient builds** - Layer caching and minimal build context

### Scope

This standard applies to all HyperFleet repositories that produce container images (repository type `service` in `.hyperfleet.yaml`).

---

## Base Images

### Builder Stage

All Go service Dockerfiles **MUST** use Red Hat UBI9 Go toolset as the builder image:

```dockerfile
FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder
```

**Why UBI9 Go toolset?**
- Red Hat-supported and maintained
- FIPS-validated cryptographic libraries available
- Consistent with Red Hat OpenShift ecosystem
- Regular security updates

> **Note:** The Go toolset image does not include `make` by default. Install it as root, then switch back to the non-root user (see [Multi-Stage Build Pattern](#multi-stage-build-pattern)).

### Production Runtime

The default production runtime image **MUST** be a minimal, distroless image:

```dockerfile
ARG BASE_IMAGE=gcr.io/distroless/static-debian12:nonroot
FROM ${BASE_IMAGE}
```

Using `ARG BASE_IMAGE` makes the runtime configurable for different build scenarios:

| Scenario | Base Image | Notes |
|----------|-----------|-------|
| Standard (static binary, `CGO_ENABLED=0`) | `gcr.io/distroless/static-debian12:nonroot` | Default. No libc, smallest footprint |
| FIPS-compliant (`CGO_ENABLED=1`) | `registry.access.redhat.com/ubi9-micro` | Requires glibc for boringcrypto |
| Development / debugging | `alpine:3.21` | Includes shell for troubleshooting |

---

## Multi-Stage Build Pattern

All service Dockerfiles **MUST** use multi-stage builds with the following structure:

```dockerfile
ARG BASE_IMAGE=gcr.io/distroless/static-debian12:nonroot

# ── Builder stage ──
FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG VERSION=""

USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001

ENV GOBIN=/build/.gobin
RUN mkdir -p $GOBIN

COPY --chown=1001:0 go.mod go.sum ./
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    go mod download

COPY --chown=1001:0 . .

RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    --mount=type=cache,target=/opt/app-root/src/.cache/go-build,uid=1001 \
    CGO_ENABLED=0 GOOS=linux \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} VERSION=${VERSION} \
    make build

# ── Runtime stage ──
FROM ${BASE_IMAGE}

WORKDIR /app
COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]
```

### Key Practices

- **Cache mounts** for Go module and build caches to speed up rebuilds
- **`go mod download`** as a separate layer before copying source for better layer caching
- **`--chown=1001:0`** on COPY commands for the builder stage (UBI9 convention)
- **`WORKDIR /app`** in the runtime stage to keep a clean layout
- **Build args** passed through to `make build` for version embedding

---

## Non-Root Users

All container images **MUST** run as non-root users.

### Builder Stage (UBI9 Go Toolset)

The UBI9 Go toolset image provides user `1001` by default. Temporarily switch to `root` only when installing system packages, then switch back:

```dockerfile
USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001
```

### Runtime Stage

Use the standard nonroot user `65532:65532` (matches distroless `nonroot` user):

```dockerfile
USER 65532:65532
```

---

## Go Build Parameters

### CGO_ENABLED

| Value | When to Use | Runtime Image |
|-------|-------------|---------------|
| `0` (default) | Standard builds producing static binaries | `distroless/static` (no libc needed) |
| `1` | FIPS-compliant builds with `GOEXPERIMENT=boringcrypto` | `ubi9-micro` or similar (requires glibc) |

Document this decision in your Dockerfile:

```dockerfile
# CGO_ENABLED=0 produces a static binary required for distroless runtime.
# For FIPS-compliant builds (CGO_ENABLED=1 + GOEXPERIMENT=boringcrypto), use a
# runtime image with glibc (e.g. ubi9-micro) instead of distroless.
```

### Build Flags

All Go builds **MUST** include:

| Flag | Purpose |
|------|---------|
| `-trimpath` | Remove local filesystem paths from binary for reproducibility |
| `-s -w` (via `-ldflags`) | Strip debug symbols to reduce binary size |
| `-X` (via `-ldflags`) | Embed version, commit hash, and build date |

Standard ldflags:

```makefile
LDFLAGS := -s -w \
           -X main.version=$(VERSION) \
           -X main.commit=$(GIT_SHA) \
           -X main.date=$(BUILD_DATE)
```

### Platform

Container builds **MUST** specify the target platform:

```makefile
PLATFORM ?= linux/amd64
```

```bash
$(CONTAINER_TOOL) build --platform $(PLATFORM) ...
```

---

## Container Labels

All production images **MUST** include standardized OCI labels. Place the `LABEL` instruction at the end of the Dockerfile (after `ARG` re-declarations) so it doesn't invalidate earlier layer caches:

```dockerfile
ARG VERSION=""
LABEL name="<service-name>" \
      vendor="Red Hat" \
      version="${VERSION}" \
      summary="<one-line summary>" \
      description="<detailed description of what the service does>"
```

### Required Labels

| Label | Description | Example |
|-------|-------------|---------|
| `name` | Service name (matches image name) | `hyperfleet-sentinel` |
| `vendor` | Organization | `Red Hat` |
| `version` | Semantic version or git-derived version | `abc1234` |
| `summary` | One-line description | `HyperFleet Sentinel - Resource polling and event publishing service` |
| `description` | Detailed description of the service | `Watches HyperFleet API resources and publishes reconciliation events to message brokers` |

---

## .dockerignore

All repositories producing container images **MUST** include a `.dockerignore` file at the repository root. At minimum, it **MUST** exclude the `.git/` directory:

```dockerignore
.git/
bin/
build/
coverage.out
coverage.txt
coverage.html
*.md
!README.md
LICENSE
.vscode/
.idea/
```

### Why?

- **Prevents `-buildvcs` errors**: Git metadata inside the build context causes failures with Go's VCS stamping during container builds
- **Reduces build context size**: The `.git/` directory can be large and is never needed inside the container
- **Faster builds**: Smaller context means faster transfer to the Docker daemon

---

## Reference Dockerfile

A complete reference Dockerfile incorporating all standards above. Replace `<service-name>` with the actual service binary name:

```dockerfile
ARG BASE_IMAGE=gcr.io/distroless/static-debian12:nonroot

FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS builder

ARG GIT_SHA=unknown
ARG GIT_DIRTY=""
ARG BUILD_DATE=""
ARG VERSION=""

USER root
RUN dnf install -y make && dnf clean all
WORKDIR /build
RUN chown 1001:0 /build
USER 1001

ENV GOBIN=/build/.gobin
RUN mkdir -p $GOBIN

COPY --chown=1001:0 go.mod go.sum ./
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    go mod download

COPY --chown=1001:0 . .

# CGO_ENABLED=0 produces a static binary required for distroless runtime.
# For FIPS-compliant builds (CGO_ENABLED=1 + GOEXPERIMENT=boringcrypto), use a
# runtime image with glibc (e.g. ubi9-micro) instead of distroless.
RUN --mount=type=cache,target=/opt/app-root/src/go/pkg/mod,uid=1001 \
    --mount=type=cache,target=/opt/app-root/src/.cache/go-build,uid=1001 \
    CGO_ENABLED=0 GOOS=linux \
    GIT_SHA=${GIT_SHA} GIT_DIRTY=${GIT_DIRTY} BUILD_DATE=${BUILD_DATE} VERSION=${VERSION} \
    make build

FROM ${BASE_IMAGE}

WORKDIR /app
COPY --from=builder /build/bin/<service-name> /app/<service-name>

USER 65532:65532

EXPOSE 8080
ENTRYPOINT ["/app/<service-name>"]

ARG VERSION=""
LABEL name="<service-name>" \
      vendor="Red Hat" \
      version="${VERSION}" \
      summary="<one-line service summary>" \
      description="<detailed service description>"
```

---

## References

### Related Documents

- [Makefile Conventions](makefile-conventions.md) - Standard Makefile targets and variables
- [Directory Structure Standard](directory-structure.md) - Standard repository layout

### External Resources

- [Red Hat UBI9 Go Toolset](https://catalog.redhat.com/software/containers/ubi9/go-toolset)
- [Google Distroless Images](https://github.com/GoogleContainerTools/distroless)
- [OCI Image Spec - Annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
- [Dockerfile Best Practices](https://docs.docker.com/build/building/best-practices/)
