# Provider catalogs

Bundled static model catalogs for frontier text-inference providers (`openai`, `anthropic`, `openrouter`).

Each provider ships a `{providerId}.catalog.json` file consumed at runtime by `ProviderCatalogLoader`. Hand-curated corrections live in `overrides/{providerId}.overrides.json` and are merged by the generation script.

### Logical model identity

Optional catalog fields for cross-provider binding merge:

| Field | Role |
|-------|------|
| `canonicalModelKey` | Stable logical identity (e.g. `claude-sonnet-4-6`). Rows with the same key merge into one registry entry with multiple bindings. |
| `modelFamily` | Coarse family for `ModelQuery.preferredFamily` ranking (e.g. `claude-sonnet`). Distinct from `canonicalModelKey`. |

Local API-server maps on `InferenceRuntimeConfig.modelIDMap` support the same fields on `ModelConfig`.

## Regeneration

From the repository root:

```bash
python3 Scripts/generate-provider-catalogs.py
python3 Scripts/generate-provider-catalogs.py --fetch   # optional vendor API merge
python3 Scripts/generate-provider-catalogs.py --provider openai --fetch
```

`--fetch` contacts vendor APIs where available (`openai`, `openrouter`). Anthropic has no public models list API; maintain its seed catalog manually or via overrides.

The script preserves existing `registryId`, `canonicalModelKey`, and `modelFamily` values when `endpointModelId` is unchanged.
