#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/openapi/openapi.yaml"
CLIENT_INPUT="$ROOT/Sources/SileniaAIClient/openapi.yaml"
REL_TARGET="../../openapi/openapi.yaml"

if [ ! -f "$CANONICAL" ]; then
  echo "Canonical OpenAPI spec not found at $CANONICAL" >&2
  exit 1
fi

rm -f "$CLIENT_INPUT"
ln -s "$REL_TARGET" "$CLIENT_INPUT"
echo "Linked $CLIENT_INPUT -> $REL_TARGET"
