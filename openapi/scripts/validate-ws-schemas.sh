#!/usr/bin/env bash
# Optional Node-based cross-check for JSON Schema 2020-12 fixtures (developer machine).
# CI and package tests use ``WebSocketSchemaFixtureTests`` — run:
#   swift test --filter WebSocketSchemaFixtureTests
#
# With Node + npm:
#   cd openapi/schemas/ws && npx ajv-cli validate -s comm-client-control.schema.json -d fixtures/comm-client-control-valid-subscribe.json
set -euo pipefail
echo "Primary WS fixture validation: swift test --filter WebSocketSchemaFixtureTests"
echo "Optional: run ajv-cli manually against openapi/schemas/ws/*.schema.json (see script comments)."
exit 0
