#!/bin/bash
# Open one PR per repository that replaces its OWNERS files with the rendered set
# from hack/owners/out. Run gen_owners.py render first.
#
# Usage: hack/owners/open_prs.sh [--dry-run] [--draft] [repo ...]
# Pushes to a branch on the caller's fork (created if missing) and opens the PR
# with gh. Existing OWNERS files that the generator does not produce are removed,
# so stale per-directory files go in the same change. With --draft the PR opens
# as a draft and holds itself, so it cannot merge until it is marked ready and
# the hold is lifted. Runs on the bash 3.2 that macOS ships, so no mapfile,
# associative arrays or unguarded empty-array expansion under set -u.
set -euo pipefail

ORG="openshift-hyperfleet"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${ROOT}/hack/owners/out"
BRANCH="${BRANCH:-HYPERFLEET-1762-owners-files}"
TITLE="${TITLE:-HYPERFLEET-1762 - chore: narrow OWNERS to area owners and aliases}"
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

if [[ $# -gt 0 ]]; then
  REPOS=("$@")
else
  if [[ ! -d "${OUT}" ]]; then
    echo "rendered OWNERS directory not found: ${OUT} (run 'make owners' first)" >&2
    exit 1
  fi
  REPOS=()
  while IFS= read -r line; do REPOS+=("${line}"); done < <(ls -A "${OUT}")
fi
if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "nothing rendered under ${OUT} (run 'make owners' first)" >&2
  exit 1
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
  # never stage a root OWNERS deletion: the rendered set for this repository must exist
  if [[ ! -f "${src}/OWNERS" ]]; then
    echo "no rendered root OWNERS for ${repo} at ${src}/OWNERS (not in owners.yaml, or run 'make owners')" >&2
    exit 1
  fi
  git clone --quiet "git@github.com:${ORG}/${repo}.git" "${dir}"
  (
    cd "${dir}"
    git checkout -q -b "${BRANCH}"
    # remove every tracked OWNERS and OWNERS_ALIASES, then copy the rendered set.
    # git ls-files failures stay fatal; only grep's "no match" (exit 1) is tolerated,
    # because a repository with no OWNERS yet is fine.
    # NUL-separated lists go through files: command substitution would drop the NULs.
    git ls-files -z > "${WORK}/${repo}.tracked"
    grep -z -E '(^|/)OWNERS(_ALIASES)?$' "${WORK}/${repo}.tracked" > "${WORK}/${repo}.owners" || [[ $? -eq 1 ]]
    xargs -0 -r git rm -q < "${WORK}/${repo}.owners"
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
    # Push to the caller's fork, or to a branch on the org repository when the
    # caller's copy is not registered as a fork (GitHub refuses a cross-repo PR then).
    if [[ "${PUSH_TO_ORIGIN:-0}" -eq 1 ]]; then
      remote="origin"
      head_owner="${ORG}"
      head_ref="${BRANCH}"
    else
      remote="fork"
      head_owner="${FORK_OWNER}"
      head_ref="${FORK_OWNER}:${BRANCH}"
      if ! gh repo view "${FORK_OWNER}/${repo}" >/dev/null 2>&1; then
        gh repo fork "${ORG}/${repo}" --clone=false >/dev/null
      fi
      git remote add fork "git@github.com:${FORK_OWNER}/${repo}.git"
    fi
    # An existing remote branch is only overwritten when it is this workflow's: an open
    # PR in the org repository with that head, the expected owner and this title. The
    # update is then leased on the OID observed here, never a blind force push.
    remote_oid="$(git ls-remote "${remote}" "refs/heads/${BRANCH}" | cut -f1)"
    existing="$(gh pr list --repo "${ORG}/${repo}" --state open --head "${BRANCH}" \
      --json url,title,headRefName,headRepositoryOwner |
      jq -r --arg owner "${head_owner}" --arg branch "${BRANCH}" --arg title "${TITLE}" \
        '[.[] | select(.headRepositoryOwner.login == $owner and .headRefName == $branch and .title == $title)][0].url // empty')"
    if [[ -z "${remote_oid}" ]]; then
      git push -q "${remote}" "${BRANCH}"
    elif [[ -n "${existing}" ]]; then
      git push -q --force-with-lease="${BRANCH}:${remote_oid}" "${remote}" "${BRANCH}"
    else
      echo "  branch ${BRANCH} already exists on ${remote} (${remote_oid:0:7}) with no open PR titled '${TITLE}' from ${head_owner}; refusing to overwrite. Set BRANCH to a different name or remove the branch." >&2
      exit 1
    fi
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
    # ${arr[@]+"${arr[@]}"} is the empty-array form that bash 3.2 accepts under set -u
    gh pr create --repo "${ORG}/${repo}" --head "${head_ref}" --base main \
      ${draft_flag[@]+"${draft_flag[@]}"} --title "${TITLE}" --body "${body}"
  )
done
