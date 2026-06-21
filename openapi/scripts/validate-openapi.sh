#!/usr/bin/env bash
# Lint OpenAPI with Spectral (optional Node/npx). Usage from repo root:
#   bash SwiftAgentHarness/openapi/scripts/validate-openapi.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="$ROOT/openapi/openapi.yaml"
RULES="$ROOT/openapi/.spectral.yaml"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx not found; install Node.js or run: npm install -g @stoplight/spectral-cli" >&2
  exit 1
fi

exec npx --yes @stoplight/spectral-cli lint "$SPEC" --ruleset "$RULES"
