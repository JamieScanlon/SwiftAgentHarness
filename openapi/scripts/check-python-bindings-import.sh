#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV="$ROOT/.openapi-bindings-venv"
PY="$VENV/bin/python"

if [ ! -x "$PY" ]; then
  echo "Python bindings venv missing. Run generate-python-bindings.sh first." >&2
  exit 1
fi

PYTHONPATH="$ROOT/openapi/generated" "$PY" - <<'PY'
import python as bindings

assert hasattr(bindings, "rest_models")
assert hasattr(bindings, "ws")
print("Python binding import smoke check passed.")
PY
