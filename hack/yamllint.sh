#!/bin/bash
set -euo pipefail

echo "Running yamllint..."
find . -type f \( -name "*.yaml" -o -name "*.yml" \) -not -path "./.git/*" | xargs yamllint
echo "yamllint passed."
