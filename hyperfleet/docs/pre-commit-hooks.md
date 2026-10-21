---
Status: Active
Owner: HyperFleet Platform Team
Last Updated: 2026-10-21
---

# Pre-Commit Hooks Setup Guide

> Setup, configuration, and usage guide for HyperFleet's centralized pre-commit hooks. Covers installation, project-specific configurations, and migration steps for adding hooks to existing repositories.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Available Hooks](#available-hooks)
4. [Standard Configuration](#standard-configuration)
5. [Migration Guide](#migration-guide)
6. [Troubleshooting](#troubleshooting)
7. [References](#references)

---

## Overview

HyperFleet uses a **centralized hook registry** at [`hyperfleet-hooks`](https://github.com/openshift-hyperfleet/hyperfleet-hooks) to enforce consistent commit message format and code quality across all repositories. Additionally, **LeakTK** provides secret scanning to prevent credentials and API keys from being committed. The [pre-commit](https://pre-commit.com/) framework automatically downloads, builds, and caches hook binaries — no manual installation of individual tools is required.

### How It Works

```text
hyperfleet-hooks repository (centralized)
├── .pre-commit-hooks.yaml    # Hook definitions
├── cmd/                      # commitlint Go binary
└── docs/                     # Hook documentation

         ▼ consumed by pre-commit framework ▼

Any HyperFleet repository (consumer)
├── .pre-commit-config.yaml   # Selects which hooks to use
└── Makefile                  # install-hooks target
```

When a developer runs `git commit`, the pre-commit framework intercepts the operation, runs the configured hooks, and blocks the commit if any hook fails. This provides immediate feedback before code reaches CI.

---

## Prerequisites

- [pre-commit](https://pre-commit.com/#install) installed:

  ```bash
  pip install pre-commit
  ```

- A Go toolchain satisfying the pinned Go hooks' module requirements (both `commitlint` and LeakTK are built automatically by pre-commit on first run). In Go repositories, also match the consuming repo's `go.mod`, `tools/go.mod`, and supported Go versions of the pinned tools; a newer installed Go version is not automatically compatible. See [Go tooling fails with a newer installed Go version](#go-tooling-fails-with-a-newer-installed-go-version).
- `make` targets (`lint`, `gofmt`, `go-vet`) in the consuming repo (for Go tooling hooks)

**LeakTK builds with `CGO_ENABLED=0` by default** — no system dependencies required. This works on all platforms (Linux, macOS, Windows).

<details>
<summary>Optional: Building LeakTK with CGO enabled</summary>

If you need CGO support, install the following system dependencies before running `make install-hooks`:

```bash
# Fedora/RHEL
sudo dnf install btrfs-progs-devel

# Ubuntu/Debian
sudo apt install libbtrfs-dev
```

Then set `CGO_ENABLED=1` in your environment.

</details>

---

## Available Hooks

### HyperFleet Hooks

All hooks are defined in the [`hyperfleet-hooks`](https://github.com/openshift-hyperfleet/hyperfleet-hooks) repository:

| Hook ID | Stage | Language | Description |
|---------|-------|----------|-------------|
| `hyperfleet-commitlint` | `commit-msg` | `golang` | Validates commit messages against the [HyperFleet Commit Standard](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/commit-standard.md) |
| `hyperfleet-golangci-lint` | `pre-commit` | `system` | Runs `make lint` — delegates to the repo's bingo-managed golangci-lint |
| `hyperfleet-gofmt` | `pre-commit` | `system` | Runs `make gofmt` — checks Go file formatting |
| `hyperfleet-go-vet` | `pre-commit` | `system` | Runs `make go-vet` — finds suspicious constructs in Go code |

The Go tooling hooks use `language: system` and delegate to existing Make targets rather than reimplementing tool resolution. This leverages each repo's [bingo](https://github.com/bwplotka/bingo)-managed tool versions (see [dependency pinning standard](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/dependency-pinning.md)).

### Secret Scanning Hook

**LeakTK** provides secret scanning to prevent credentials, API keys, and other secrets from being committed:

| Hook ID | Stage | Language | Description |
|---------|-------|----------|-------------|
| `leaktk.git.pre-commit` | `pre-commit` | `golang` | LeakTK: Scans staged files for secrets using Gitleaks engine with Red Hat-specific patterns |

**Key features**:

- ✅ **Open-source** — no VPN requirement, works for all contributors
- ✅ **Developed by Red Hat InfoSec** — same team that created rh-pre-commit
- ✅ **Gitleaks-powered** — uses proven secret detection patterns
- ⏱️ **First-time compilation** — takes 3-5 minutes on first commit, then cached

See the [Secret Scanning Migration](#secret-scanning-migration-rh-pre-commit--leaktk) section for migration details.

---

## Standard Configuration

All HyperFleet repositories **SHOULD** use the same `.pre-commit-config.yaml`. The Go tooling hooks (`gofmt`, `golangci-lint`, `go-vet`) use `types: [go]` filtering, so they only trigger when Go files are staged — in non-Go repos they are simply skipped.

```yaml
# .pre-commit-config.yaml
# Installs both pre-commit and commit-msg hooks with a single `pre-commit install`
default_install_hook_types: [pre-commit, commit-msg]

repos:
  # Secret scanning
  - repo: https://github.com/leaktk/leaktk
    rev: c6f5a11329736a8dc1551a84603f117bd9ed498e  # frozen: v0.3.12
    hooks:
      - id: leaktk.git.pre-commit

  # HyperFleet code quality hooks
  - repo: https://github.com/openshift-hyperfleet/hyperfleet-hooks
    rev: d9aab6d723c9246bd2f63a982bf1d9cf0805b3a4  # frozen: v0.3.0
    hooks:
      - id: hyperfleet-commitlint
        stages: [commit-msg]
      - id: hyperfleet-gofmt
      - id: hyperfleet-golangci-lint
      - id: hyperfleet-go-vet

  # File hygiene
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: 3e8a8703264a2f4a69428a0aa4dcb512790b2c8c  # frozen: v6.0.0
    hooks:
      - id: trailing-whitespace
        args: [--markdown-linebreak-ext=md]
      - id: end-of-file-fixer
      - id: check-added-large-files
```

The file hygiene hooks (`trailing-whitespace`, `end-of-file-fixer`, `check-added-large-files`) catch common issues — trailing whitespace, missing final newlines, and accidentally committed large binaries — before they reach PR review. `--markdown-linebreak-ext=md` preserves intentional two-space Markdown hard line breaks.

> **Important:** All remote hook `rev` values **MUST** use full 40-character Git SHAs, not mutable tags or branches (see [CVE-2025-30066](https://www.cve.org/CVERecord?id=CVE-2025-30066)). Use the trailing comment `# frozen: <tag>` so Renovate can extract the release version separately from its digest and preserve SHA pinning. Generate updates with:
>
> ```bash
> pre-commit autoupdate --freeze
> ```
>
> Inspect every remote `rev` after updating: already-current entries can retain an old comment and need explicit conversion to `# frozen: <tag>`. For annotated tags, `--freeze` may pin the immutable tag-object SHA rather than the peeled commit SHA; both resolve to the release, but verify the tag and its target before accepting a change. See [Updating hook versions](#updating-hook-versions) for verification steps.
>
> **Note:** `default_install_hook_types: [pre-commit, commit-msg]` means a single `pre-commit install` command installs hooks for **both** the `pre-commit` and `commit-msg` stages. Without this setting, you would need to run `pre-commit install --hook-type commit-msg` separately to enable commit message validation.
>
> **Important:** On the **first commit** after running `make install-hooks`, LeakTK will compile from source (3-5 minutes). Subsequent commits use the cached binary and run instantly.

---

## Migration Guide

This section covers two migration scenarios:

1. **Adding Pre-commit Hooks** — adding hooks to an existing HyperFleet repository
2. **Secret Scanning Migration** — migrating from rh-pre-commit to LeakTK

---

### Adding Pre-commit Hooks to a Repository

Follow these steps to add pre-commit hooks to an existing HyperFleet repository.

#### Step 1: Add `.pre-commit-config.yaml`

Copy the [Standard Configuration](#standard-configuration) into a `.pre-commit-config.yaml` file in the repo root.

#### Step 2: Add `install-hooks` Makefile target

Add the target to your Makefile (see [Makefile Conventions — Optional Targets](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/makefile-conventions.md#optional-targets)):

```makefile
.PHONY: install-hooks
install-hooks: ## Install pre-commit hooks
 pre-commit install
```

#### Step 3: Add Make aliases for Go tooling hooks (Go repos only)

The Go tooling hooks expect `make gofmt` and `make go-vet` targets. If your repo uses different names (e.g., `fmt` and `vet`), add aliases:

```makefile
.PHONY: gofmt
gofmt: fmt ## Alias for fmt

.PHONY: go-vet
go-vet: vet ## Alias for vet
```

#### Step 4: Update documentation

Add `pre-commit` to the prerequisites section in your `README.md`:

```markdown
### Prerequisites

- Go toolchain matching the repository and pinned hooks/tools
- Docker or Podman
- Make
- pre-commit
```

Add the hook installation step to your getting started section or `CONTRIBUTING.md`:

```markdown
### Getting Started

# ... existing steps ...

# Install git hooks
make install-hooks
```

#### Step 5: Install and verify

```bash
make install-hooks
```

Test with valid commits (both formats are accepted):

```bash
git commit --allow-empty -m "test: verify pre-commit hooks"
git commit --allow-empty -m "HYPERFLEET-XXX - test: verify pre-commit hooks"
```

Test with an invalid commit (should fail):

```bash
git commit --allow-empty -m "bad commit message"
```

#### Step 6: Fix existing violations

Run hooks against the entire codebase to fix any pre-existing violations (trailing whitespace, missing EOF newlines, etc.). Without this step, the first contributor who touches an unrelated file with a trailing whitespace or missing newline gets a hook failure they didn't cause.

```bash
pre-commit run --all-files
```

Review auto-fixes, stage them, and commit as a **separate companion PR** so the cleanup doesn't muddy the diff of the hook configuration PR:

```bash
git add -p
git commit -m "HYPERFLEET-XXX - chore: fix pre-commit baseline violations"
```

#### Step 7: Commit the hook configuration

```bash
git add .pre-commit-config.yaml Makefile README.md CONTRIBUTING.md
git commit -m "HYPERFLEET-XXX - chore: add pre-commit hooks"
```

---

### Secret Scanning Migration: rh-pre-commit → LeakTK

#### Why Migrate to LeakTK?

[**LeakTK**](https://github.com/leaktk/leaktk) is an open-source secret scanning toolkit developed by Red Hat's Information Security team — the same team that created rh-pre-commit.

**Key benefits over rh-pre-commit**:

- ✅ **No VPN requirement** — works for Red Hat associates and external contributors
- ✅ **Open-source** — MIT licensed, publicly accessible on GitHub
- ✅ **Can be committed to repos** — configuration lives in repository files
- ✅ **Enforces on all developers** — configuration in repo ensures everyone uses it
- ✅ **Same detection engine** — both use Gitleaks with Red Hat-specific patterns (verified by InfoSec team)

#### Comparison: rh-pre-commit vs LeakTK

Both tools perform secret scanning using Gitleaks as the underlying engine. Here are the key differences:

| Feature | rh-pre-commit | LeakTK |
|---------|--------------|---------|
| **Secret scanning** | ✅ Gitleaks engine | ✅ Gitleaks engine |
| **Red Hat patterns** | ✅ Customized patterns | ✅ Customized patterns |
| **VPN required** | ⚠️ Only during installation | ❌ Never |
| **Open-source** | ❌ Internal Red Hat tool | ✅ Public GitHub repository |
| **Installation** | ✅ Pre-built binary | ⚠️ Compiles from source (first time only) |

#### Migration Steps

##### Step 1: Ensure system requirements

Verify that all team members have a Go toolchain compatible with the pinned hook modules and the consuming repository's modules/tools:

```bash
go version  # Compare with the pinned hooks' and consuming repo's requirements
```

**LeakTK builds with `CGO_ENABLED=0` by default** — no additional system dependencies required. This works on all platforms (Linux, macOS, Windows).

<details>
<summary>Optional: If CGO support is needed</summary>

Install system dependencies before running `make install-hooks`:

```bash
# Fedora/RHEL
sudo dnf install btrfs-progs-devel

# Ubuntu/Debian
sudo apt install libbtrfs-dev
```

Then set `CGO_ENABLED=1` in your environment.

**Note:** macOS does not require btrfs dependencies — btrfs is a Linux-only filesystem and not available via Homebrew.

</details>

**Step 2: Update `.pre-commit-config.yaml`**

Replace the rh-pre-commit configuration with LeakTK:

```yaml
# Before (rh-pre-commit)
repos:
  - repo: https://gitlab.cee.redhat.com/infosec-public/developer-workbench/tools
    rev: rh-pre-commit-2.3.2
    hooks:
      - id: rh-pre-commit

# After (LeakTK) — SHA-pinned with the frozen release comment
repos:
  - repo: https://github.com/leaktk/leaktk
    rev: c6f5a11329736a8dc1551a84603f117bd9ed498e  # frozen: v0.3.12
    hooks:
      - id: leaktk.git.pre-commit
```

##### Step 3: Notify team

Inform all developers that:

1. System requirements must match the pinned hooks and the consuming repo's modules/tools
2. They should reinstall hooks: `make install-hooks`
3. The **first commit** will take 3-5 minutes (one-time compilation)
4. Subsequent commits will run instantly (cached binary)

##### Step 4: Commit the migration

```bash
git add .pre-commit-config.yaml
git commit -m "HYPERFLEET-XXX - chore: migrate from rh-pre-commit to LeakTK"
```

##### Step 5: Update CI/CD pipelines

If your repository enforces hooks in CI, update your pipeline configuration to use LeakTK instead of rh-pre-commit. The following steps apply regardless of CI platform (Prow, GitHub Actions, GitLab CI, etc.):

1. **Ensure a compatible Go toolchain is available** in your CI environment, matching the pinned hook modules and consuming repo's modules/tools
   - Verify with `go version` or install if needed

2. **Install pre-commit framework**:

   ```bash
   pip install pre-commit
   ```

3. **Run the repository's hook installation target** to ensure consistent setup:

   ```bash
   make install-hooks
   ```

   This mirrors the developer workflow and ensures pre-commit hooks are registered. The first run compiles LeakTK (3-5 minutes) — cache to avoid recompilation on subsequent runs.

4. **Cache the pre-commit environment** to avoid recompiling LeakTK on every run
   - Cache directory: `~/.cache/pre-commit/`
   - Cache key: tie to `.pre-commit-config.yaml` content (e.g., hash of the file)
   - This reduces subsequent runs from minutes to seconds

5. **Replace rh-pre-commit invocations** with pre-commit:

   ```bash
   # Before (rh-pre-commit)
   rh-pre-commit run --all-files

   # After (pre-commit with LeakTK)
   pre-commit run --all-files
   ```

   **Note:** If your repo uses the `make install-hooks` wrapper, you can also run hooks via `make` targets that delegate to pre-commit.

**Notes:**

- The **first pipeline run** after migration compiles LeakTK (3-5 minutes). Subsequent runs use the cached binary.
- **LeakTK builds with `CGO_ENABLED=0` by default** — no btrfs-progs-devel or other system dependencies required.
- Search for `rh-pre-commit`, `LeakTK`, `make install-hooks`, and `pre-commit` in your CI configuration to locate and update all relevant pipeline steps.

#### What Changes After Migration

**During development**:

```bash
# First commit after migration (one-time)
git commit -m "feat: add feature"
# LeakTK compiles (3-5 minutes), then scans
# ✅ Commit succeeds if no secrets found

# All subsequent commits
git commit -m "feat: another feature"
# LeakTK uses cached binary (instant)
```

**Example output when a secret is detected**:

```text
leaktk.git.pre-commit
┌─────────────────────────────────────────────────────────────────────────────┐
│ 1 secret(s) detected in staged files                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ config/database.yml:12                                                      │
│ Password = "admin123"  # Generic Password                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

The commit will be blocked until secrets are removed.

---

## Troubleshooting

### `pre-commit: command not found`

Install the pre-commit framework:

```bash
pip install pre-commit
```

Or via Homebrew on macOS:

```bash
brew install pre-commit
```

### `make: *** No rule to make target 'gofmt'`

Your Makefile needs the `gofmt` alias. Add it pointing to your existing formatting target:

```makefile
.PHONY: gofmt
gofmt: fmt ## Alias for fmt
```

### LeakTK compilation fails with "Go version too old"

Check the pinned LeakTK release's `go.mod` and the consuming repository's toolchain requirements rather than relying on a version copied from this guide:

```bash
# Check version
go version

# Update (Fedora/RHEL)
sudo dnf update golang

# Or download from https://go.dev/dl/
```

### LeakTK compilation fails with "btrfs/ioctl.h: No such file or directory"

This error occurs when LeakTK tries to build with CGO enabled but the btrfs development headers are missing.

**Solution 1 (Recommended):** Build without CGO — no system dependencies required:

```bash
# Clear cached build and rebuild
pre-commit clean
CGO_ENABLED=0 pre-commit install
```

**Solution 2:** Install btrfs development headers (Linux only):

```bash
# Fedora/RHEL
sudo dnf install btrfs-progs-devel

# Ubuntu/Debian
sudo apt install libbtrfs-dev
```

**Note:** macOS users should use Solution 1 — btrfs is Linux-only and not available on macOS.

### First commit takes 3-5 minutes

This is **expected behavior** on the first commit after installing LeakTK. The pre-commit framework is compiling LeakTK from source. Subsequent commits will use the cached binary and run instantly.

### Hook runs but uses wrong tool version

Pre-commit caches hook environments. Clear the cache and reinstall:

```bash
pre-commit clean
pre-commit install
```

### Go tooling fails with a newer installed Go version

The Go tooling hooks run the consuming repo's Make targets, so compatibility depends on that repo's `go.mod`, `tools/go.mod`, and pinned tools. A newer installed Go version can exceed the Go versions supported by its pinned golangci-lint.

For example, a repo pinning golangci-lint v2.7.0 can fail on Go 1.27. If Go 1.26.0 satisfies that repo's module requirements, use this repo-specific workaround:

```bash
GOTOOLCHAIN=go1.26.0 pre-commit run --all-files
```

This is an example, not a fleet-wide Go version requirement. Use a compatible toolchain selected for the repo, or update the pinned linter through the repo's normal dependency review process; clearing the pre-commit cache does not fix an unsupported host toolchain.

### Skipping hooks temporarily

In rare cases (e.g., merge commits), you can skip hooks:

```bash
git commit --no-verify -m "HYPERFLEET-123 - chore: merge conflict resolution"
```

Use this sparingly — CI will still validate the commit message on the PR.

### Updating hook versions

Use frozen updates to retain SHA pinning while recording the release version:

```bash
pre-commit autoupdate --freeze

# Or update one hook source only
pre-commit autoupdate --freeze --repo https://github.com/leaktk/leaktk

# Verify both the tag object and peeled commit for annotated tags
git ls-remote https://github.com/openshift-hyperfleet/hyperfleet-hooks.git \
  'refs/tags/v0.3.0' 'refs/tags/v0.3.0^{}'

git diff -- .pre-commit-config.yaml
pre-commit validate-config
pre-commit run --all-files
```

Every remote entry must have the form `rev: <40-character SHA>  # frozen: <tag>`. If `autoupdate --freeze` leaves an already-current entry unchanged, verify its release reference and normalize the comment explicitly. Do not remove an existing SHA pin or invent a version comment for an unverified reference.

Renovate supports SHA-preserving updates for this format through [frozen digest support](https://github.com/renovatebot/renovate/pull/36693). Validate extraction and replacement with the Renovate version deployed by MintMaker before relying on automated updates. A local validator version or upstream image definition alone does not establish the deployed version. Keep normal human review and CI requirements; this format does not authorize auto-approval or automerge.

> **Note:** Do not use plain `pre-commit autoupdate` without `--freeze`: it writes mutable tags. Existing comments such as `# v0.3.0` are not equivalent to `# frozen: v0.3.0` for Renovate's digest extraction.

---

## References

### Related Standards

- [Commit Standard](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/commit-standard.md) — commit message format enforced by `hyperfleet-commitlint`
- [Makefile Conventions](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/makefile-conventions.md) — `install-hooks`, `gofmt`, and `go-vet` optional targets
- [Dependency Pinning](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/dependency-pinning.md) — bingo-managed tool versions used by Go hooks
- [Linting Standard](https://github.com/openshift-hyperfleet/architecture/blob/main/hyperfleet/standards/linting.md) — golangci-lint configuration

### External Resources

- [pre-commit documentation](https://pre-commit.com/)
- [hyperfleet-hooks repository](https://github.com/openshift-hyperfleet/hyperfleet-hooks)
- [Sentinel pilot PR (hyperfleet-sentinel#102)](https://github.com/openshift-hyperfleet/hyperfleet-sentinel/pull/102) — reference implementation
- [LeakTK GitHub Repository](https://github.com/leaktk/leaktk)
- [Git Hooks Installation Guide](https://github.com/leaktk/leaktk/blob/main/docs/install_git_hooks.md)
- [PR #248 - pre-commit.com integration](https://github.com/leaktk/leaktk/pull/248) ✅ Merged 2026-05-13
