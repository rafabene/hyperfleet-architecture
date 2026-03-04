#!/bin/bash
set -euo pipefail

echo "Running markdownlint..."
markdownlint-cli2 "**/*.md"
echo "markdownlint passed."
