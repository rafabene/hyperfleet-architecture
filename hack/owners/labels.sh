#!/bin/bash
# Create the area, kind and tide labels from hyperfleet/docs/owners.yaml in every
# repository listed there. Idempotent: existing labels are updated in place.
#
# Usage: hack/owners/labels.sh [--dry-run] [repo ...]
# Needs gh authenticated with write access to the repositories.
set -euo pipefail

ORG="openshift-hyperfleet"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="${ROOT}/hyperfleet/docs/owners.yaml"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

color_for() {
  case "$1" in
    area/*) echo "0052cc" ;;
    kind/*) echo "5319e7" ;;
    tide/*) echo "ededed" ;;
    *) echo "bfdadc" ;;
  esac
}

mapfile -t REPOS < <(python3 -c "import yaml; print('\n'.join(yaml.safe_load(open('${SOURCE}'))['repos']))")
if [[ $# -gt 0 ]]; then
  REPOS=("$@")
fi
mapfile -t LABELS < <(python3 -c "
import yaml
for name, desc in yaml.safe_load(open('${SOURCE}'))['labels'].items():
    print(f'{name}\t{desc}')
")

for repo in "${REPOS[@]}"; do
  echo "== ${ORG}/${repo}"
  for entry in "${LABELS[@]}"; do
    name="${entry%%$'\t'*}"
    desc="${entry#*$'\t'}"
    color="$(color_for "${name}")"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "  would create ${name} (${color}) ${desc}"
      continue
    fi
    gh label create "${name}" --repo "${ORG}/${repo}" --color "${color}" --description "${desc}" --force >/dev/null
    echo "  ${name}"
  done
done
