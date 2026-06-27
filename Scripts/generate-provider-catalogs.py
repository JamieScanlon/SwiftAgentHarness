#!/usr/bin/env python3
"""Generate bundled provider catalog JSON from optional vendor APIs and curated overrides."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
CATALOGS_DIR = REPO_ROOT / "Sources/SwiftAgentHarness/Backends/Providers/catalogs"
OVERRIDES_DIR = CATALOGS_DIR / "overrides"

PROVIDERS = ("openai", "anthropic", "openrouter")

REQUIRED_MODEL_KEYS = {"registryId", "endpointModelId", "modelProtocol"}


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=False)
        handle.write("\n")


def validate_catalog(payload: dict[str, Any]) -> None:
    if "providerId" not in payload or "models" not in payload:
        raise ValueError("catalog must include providerId and models")
    if not isinstance(payload["models"], list):
        raise ValueError("models must be an array")
    seen_ids: set[str] = set()
    for row in payload["models"]:
        if not isinstance(row, dict):
            raise ValueError("each model row must be an object")
        missing = REQUIRED_MODEL_KEYS - row.keys()
        if missing:
            raise ValueError(f"model row missing keys: {sorted(missing)}")
        endpoint_id = row["endpointModelId"]
        if endpoint_id in seen_ids:
            raise ValueError(f"duplicate endpointModelId: {endpoint_id}")
        seen_ids.add(endpoint_id)


def catalog_path(provider_id: str) -> Path:
    return CATALOGS_DIR / f"{provider_id}.catalog.json"


def overrides_path(provider_id: str) -> Path:
    return OVERRIDES_DIR / f"{provider_id}.overrides.json"


def index_models(models: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {row["endpointModelId"]: row for row in models}


def fetch_openai_models() -> list[dict[str, Any]]:
    api_key = os.environ.get("OPENAI_API_KEY") or os.environ.get("SAH_OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY or SAH_OPENAI_API_KEY required for --fetch openai")
    request = urllib.request.Request(
        "https://api.openai.com/v1/models",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    rows: list[dict[str, Any]] = []
    for item in payload.get("data", []):
        model_id = item.get("id")
        if not isinstance(model_id, str):
            continue
        rows.append(
            {
                "endpointModelId": model_id,
                "displayName": model_id,
                "modelProtocol": "openAIAPI",
                "capabilities": ["completion"],
            }
        )
    return rows


def fetch_openrouter_models() -> list[dict[str, Any]]:
    request = urllib.request.Request("https://openrouter.ai/api/v1/models")
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = json.load(response)
    rows: list[dict[str, Any]] = []
    for item in payload.get("data", []):
        model_id = item.get("id")
        if not isinstance(model_id, str):
            continue
        pricing = item.get("pricing") or {}
        cost: dict[str, Any] = {}
        prompt = pricing.get("prompt")
        completion = pricing.get("completion")
        cache_read = pricing.get("input_cache_read")
        if prompt is not None:
            cost["inputPer1MUSD"] = float(prompt) * 1_000_000
        if completion is not None:
            cost["outputPer1MUSD"] = float(completion) * 1_000_000
        if cache_read is not None:
            cost["cachedInputPer1MUSD"] = float(cache_read) * 1_000_000
        row: dict[str, Any] = {
            "endpointModelId": model_id,
            "displayName": item.get("name") or model_id,
            "modelProtocol": "openAIAPI",
            "capabilities": ["completion", "tools"],
        }
        context_length = item.get("context_length")
        if isinstance(context_length, int):
            row["maxContextLength"] = context_length
        if cost:
            row["cost"] = cost
        rows.append(row)
    return rows


def fetch_vendor_models(provider_id: str) -> list[dict[str, Any]]:
    if provider_id == "openai":
        return fetch_openai_models()
    if provider_id == "openrouter":
        return fetch_openrouter_models()
    if provider_id == "anthropic":
        raise RuntimeError("anthropic has no public models list API; maintain seed catalog manually")
    raise RuntimeError(f"unsupported provider: {provider_id}")


def preserve_registry_ids(
    merged: dict[str, dict[str, Any]],
    existing: dict[str, dict[str, Any]],
) -> None:
    for endpoint_id, row in merged.items():
        if endpoint_id in existing and "registryId" in existing[endpoint_id]:
            row["registryId"] = existing[endpoint_id]["registryId"]


def apply_overrides(
    merged: dict[str, dict[str, Any]],
    overrides_doc: dict[str, Any],
) -> None:
    override_models = overrides_doc.get("models") or {}
    if not isinstance(override_models, dict):
        raise ValueError("overrides.models must be an object keyed by endpointModelId")
    for endpoint_id, overlay in override_models.items():
        if endpoint_id not in merged:
            merged[endpoint_id] = {"endpointModelId": endpoint_id, "modelProtocol": "openAIAPI"}
        merged[endpoint_id] = deep_merge(merged[endpoint_id], overlay)


def generate_provider_catalog(provider_id: str, fetch: bool) -> dict[str, Any]:
    catalog_file = catalog_path(provider_id)
    existing_doc = load_json(catalog_file) if catalog_file.exists() else {"providerId": provider_id, "models": []}
    existing_index = index_models(existing_doc.get("models", []))

    merged: dict[str, dict[str, Any]] = deepcopy(existing_index)

    if fetch:
        try:
            fetched = fetch_vendor_models(provider_id)
        except urllib.error.URLError as error:
            raise RuntimeError(f"fetch failed for {provider_id}: {error}") from error
        for row in fetched:
            endpoint_id = row["endpointModelId"]
            if endpoint_id not in merged:
                merged[endpoint_id] = row
            else:
                merged[endpoint_id] = deep_merge(row, merged[endpoint_id])

    if overrides_path(provider_id).exists():
        overrides_doc = load_json(overrides_path(provider_id))
        apply_overrides(merged, overrides_doc)

    preserve_registry_ids(merged, existing_index)

    for endpoint_id, row in merged.items():
        row.setdefault("endpointModelId", endpoint_id)
        row.setdefault("modelProtocol", "openAIAPI")
        if "registryId" not in row:
            raise ValueError(
                f"{provider_id}/{endpoint_id}: missing registryId; add to seed catalog before generation"
            )

    output = {
        "providerId": provider_id,
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "models": sorted(merged.values(), key=lambda item: item["endpointModelId"]),
    }
    validate_catalog(output)
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--provider",
        choices=PROVIDERS,
        action="append",
        help="Limit generation to one provider (repeatable). Defaults to all.",
    )
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="Merge vendor API model lists where available (openai, openrouter).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate and print summary without writing files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    providers = args.provider or list(PROVIDERS)
    errors: list[str] = []

    for provider_id in providers:
        try:
            catalog = generate_provider_catalog(provider_id, fetch=args.fetch)
        except Exception as error:  # noqa: BLE001 - CLI aggregates failures
            errors.append(f"{provider_id}: {error}")
            continue

        if args.dry_run:
            print(f"{provider_id}: {len(catalog['models'])} models (dry run)")
            continue

        write_json(catalog_path(provider_id), catalog)
        print(f"wrote {catalog_path(provider_id)} ({len(catalog['models'])} models)")

    if errors:
        for message in errors:
            print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
