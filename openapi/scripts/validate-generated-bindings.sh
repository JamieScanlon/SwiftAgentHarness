#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "$ROOT/openapi/scripts/sync-openapi-client-input.sh"
bash "$ROOT/openapi/scripts/sync-ws-runtime-schemas.sh"
python3 "$ROOT/openapi/scripts/generate-ws-swift-bindings.py"
bash "$ROOT/openapi/scripts/generate-python-bindings.sh"

EXPECTED_LINK="../../openapi/openapi.yaml"
ACTUAL_LINK="$(readlink "$ROOT/Sources/SileniaAIClient/openapi.yaml" || true)"
if [ "$ACTUAL_LINK" != "$EXPECTED_LINK" ]; then
  echo "SileniaAIClient/openapi.yaml must be symlinked to $EXPECTED_LINK (found: $ACTUAL_LINK)" >&2
  exit 1
fi

python3 - "$ROOT/openapi/schemas/ws" "$ROOT/Sources/SileniaAIServer/Resources/WSSchemas" <<'PY'
from __future__ import annotations
import hashlib
import pathlib
import sys

canonical = pathlib.Path(sys.argv[1])
runtime = pathlib.Path(sys.argv[2])

def digest_map(base: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(base.glob("*.schema.json")):
        out[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return out

if digest_map(canonical) != digest_map(runtime):
    raise SystemExit("Runtime WS schemas are not synchronized with canonical openapi/schemas/ws")
PY

echo "Generated schema bindings were refreshed and validated."
