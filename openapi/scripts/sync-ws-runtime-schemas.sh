#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_DIR="$ROOT/openapi/schemas/ws"
RUNTIME_DIR="$ROOT/Sources/SileniaAIServer/Resources/WSSchemas"

mkdir -p "$RUNTIME_DIR"

python3 - "$CANONICAL_DIR" "$RUNTIME_DIR" <<'PY'
from __future__ import annotations
import pathlib
import shutil
import sys

canonical = pathlib.Path(sys.argv[1])
runtime = pathlib.Path(sys.argv[2])

canonical_files = sorted(p for p in canonical.glob("*.schema.json"))
if not canonical_files:
    raise SystemExit(f"no canonical WS schemas found in {canonical}")

for existing in runtime.glob("*.schema.json"):
    existing.unlink()

for src in canonical_files:
    shutil.copy2(src, runtime / src.name)

print(f"Synced {len(canonical_files)} schema files into {runtime}")
PY
