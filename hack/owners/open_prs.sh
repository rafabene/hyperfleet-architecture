#!/bin/bash
# Open one PR per repository that replaces its OWNERS files with the rendered set
# from hack/owners/out. Run gen_owners.py render first.
#
# Usage: hack/owners/open_prs.sh [--dry-run] [--draft] [repo ...]
# Pushes to a branch on the caller's fork (created if missing) and opens the PR
# with gh. Existing OWNERS files that the generator does not produce are removed,
# so stale per-directory files go in the same change. With --draft the PR opens
# as a draft and holds itself, so it cannot merge until it is marked ready and
# the hold is lifted.
set -euo pipefail

ORG="openshift-hyperfleet"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${ROOT}/hack/owners/out"
BRANCH="${BRANCH:-HYPERFLEET-1200-owners-files}"
TITLE="${TITLE:-HYPERFLEET-1200 - chore: narrow OWNERS to area owners and aliases}"
DOC_URL="https://github.com/${ORG}/architecture/blob/main/hyperfleet/docs/owners.md"
DOC_PR="${DOC_PR:-openshift-hyperfleet/architecture#232}"
DRY_RUN=0
DRAFT=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --draft) DRAFT=1 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

FORK_OWNER="$(gh api user --jq .login)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mapfile -t REPOS < <(ls "${OUT}")
if [[ $# -gt 0 ]]; then
  REPOS=("$@")
fi

read -r -d '' BODY <<EOM || true
## What changed

Replaces the flat list of approvers and reviewers with area owners from the
ownership document: ${DOC_URL}
(in review in ${DOC_PR} until it merges).

- OWNERS_ALIASES holds the names, OWNERS files reference aliases and carry area labels
- a merge now needs an approver for every touched path
- Blunderbuss requests reviewers from the area's pool

## Why

Today every repository lists the same seventeen people as approvers and
reviewers, so review requests route at random and any one of them can merge
anything alone. Named areas put the request in front of the people who know the
code and make an approver accountable for what merges.

**The same criteria were applied to everyone at launch, using the last three
sprints. Reviewer and approver status follows the criteria in the ownership
document and nothing else.** The path to reviewer and approver is written there.

Generated from hyperfleet/docs/owners.yaml in the architecture repository.
Changes to ownership are a PR to that file, then a regenerated OWNERS here.

## Merge order

This is one of the nineteen per-repository OWNERS PRs, step 5 of the
repository ownership rollout. It merges after the team session and after the
ownership document, and only when the hold is lifted.

1. ${DOC_PR}, ownership document and generator.
2. openshift-hyperfleet/hyperfleet-hooks commitlint PR, then the v0.3.0 tag.
3. openshift/release#86872, Prow onboarding and the tide context.
4. Team session.
5. **This PR** with the other eighteen OWNERS PRs, after 1, 3 and 4.
6. openshift/release#86873, squash on merge, after 2 and 4.
7. hyperfleet-claude-plugins digest PR, any time after 5.
EOM

for repo in "${REPOS[@]}"; do
  echo "== ${ORG}/${repo}"
  src="${OUT}/${repo}"
  dir="${WORK}/${repo}"
  git clone --quiet "https://github.com/${ORG}/${repo}.git" "${dir}"
  (
    cd "${dir}"
    git checkout -q -b "${BRANCH}"
    # remove every tracked OWNERS and OWNERS_ALIASES, then copy the rendered set
    git ls-files -z | grep -z -E '(^|/)OWNERS(_ALIASES)?$' | xargs -0 -r git rm -q
    (cd "${src}" && find . -type f -print0) | while IFS= read -r -d '' f; do
      mkdir -p "$(dirname "${f}")"
      cp "${src}/${f}" "${f}"
    done
    git add -A
    if git diff --cached --quiet; then
      echo "  no change"
      exit 0
    fi
    git --no-pager diff --cached --stat
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "  dry run, not pushing"
      exit 0
    fi
    git commit -q -m "${TITLE}"
    if ! gh repo view "${FORK_OWNER}/${repo}" >/dev/null 2>&1; then
      gh repo fork "${ORG}/${repo}" --clone=false >/dev/null
    fi
    git remote add fork "git@github.com:${FORK_OWNER}/${repo}.git"
    # the branch is ours and single purpose, so overwrite whatever a previous run left
    git push -q --force fork "${BRANCH}"
    existing="$(gh pr list --repo "${ORG}/${repo}" --state open --head "${BRANCH}" --json url --jq '.[0].url // empty')"
    if [[ -n "${existing}" ]]; then
      echo "  PR already open: ${existing}"
      exit 0
    fi
    body="${BODY}"
    draft_flag=()
    if [[ "${DRAFT}" -eq 1 ]]; then
      draft_flag=(--draft)
      body="${BODY}"$'\n\n/hold'
    fi
    gh pr create --repo "${ORG}/${repo}" --head "${FORK_OWNER}:${BRANCH}" --base main \
      "${draft_flag[@]}" --title "${TITLE}" --body "${body}"
  )
done
