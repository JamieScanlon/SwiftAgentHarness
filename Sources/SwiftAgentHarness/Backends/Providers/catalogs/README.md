# Provider catalogs

Bundled static model catalogs for frontier text-inference providers (`openai`, `anthropic`, `openrouter`).

Each provider ships a `{providerId}.catalog.json` file consumed at runtime by `ProviderCatalogLoader`. Hand-curated corrections live in `overrides/{providerId}.overrides.json` and are merged by the generation script.

## Regeneration

From the repository root:

```bash
python3 Scripts/generate-provider-catalogs.py
python3 Scripts/generate-provider-catalogs.py --fetch   # optional vendor API merge
python3 Scripts/generate-provider-catalogs.py --provider openai --fetch
```

`--fetch` contacts vendor APIs where available (`openai`, `openrouter`). Anthropic has no public models list API; maintain its seed catalog manually or via overrides.

The script preserves existing `registryId` values when `endpointModelId` is unchanged.
