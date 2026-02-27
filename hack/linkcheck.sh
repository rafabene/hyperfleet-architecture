#!/bin/bash
set -euo pipefail

echo "Running markdown-link-check (internal links only)..."

# Create a temporary config to skip external URLs
CONFIG_FILE=$(mktemp)
cat > "${CONFIG_FILE}" <<'EOF'
{
  "ignorePatterns": [
    { "pattern": "^https?://" }
  ]
}
EOF

FAILED=0
CHECKED=0
while IFS= read -r -d '' file; do
  echo "Checking ${file}..."
  if ! markdown-link-check --quiet --config "${CONFIG_FILE}" "${file}"; then
    FAILED=1
  fi
  CHECKED=$((CHECKED + 1))
done < <(find . -type f -name "*.md" -not -path "./.git/*" -print0)

rm -f "${CONFIG_FILE}"

echo ""
echo "Checked ${CHECKED} file(s)."
if [ "${FAILED}" -ne 0 ]; then
  echo "WARNING: Some broken internal links were found (see above)."
  echo "linkcheck completed with warnings."
else
  echo "linkcheck passed — no broken internal links found."
fi
# Always exit 0 — broken links in existing docs should not block PRs.
# This job serves as an informational check.
exit 0
