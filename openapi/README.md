# Silenia OpenAPI / AsyncAPI artifacts

Phase 6 adds **schema-first** documents alongside the Swift implementation.

**Naming:** **Phase 6** here and in [FREEZE_CHECKLIST.md](./FREEZE_CHECKLIST.md) means schema/codegen artifacts for `/api` (and WS adjunct docs). That is separate from full-package server integration tests (`swift test --filter SileniaAIServerTests` in the `SileniaAIServer` package; CI: [`.github/workflows/silenia-server-tests.yml`](../../.github/workflows/silenia-server-tests.yml)) — not OpenAPI. If `swift test` blocks on “Another instance of SwiftPM…”, see [Tests README](../Tests/README.md).

## Contents

| File | Purpose |
|------|---------|
| [`openapi.yaml`](./openapi.yaml) | OpenAPI **3.1** description of `GET/POST/PUT/DELETE` under `/api` |
| [`asyncapi.yaml`](./asyncapi.yaml) | AsyncAPI **2.6** adjunct for `/ws` (see also legacy `type` frames in ARCHITECTURE) |
| [`schemas/ws/`](./schemas/ws/) | JSON Schema **2020-12** drafts for harness control + topic envelopes + payload slices (pool health, registries, conversation state, …) |
| [`FREEZE_CHECKLIST.md`](./FREEZE_CHECKLIST.md) | Preconditions before treating schemas as stable contracts |
| [`ROUTE_INVENTORY.md`](./ROUTE_INVENTORY.md) | Route matrix vs [`APILayerRESTModules.swift`](../Sources/SileniaAIServer/API/APILayerRESTModules.swift) |
| Session scope (implicit vs explicit `conversationID`) | [`Documentation/SESSION_SCOPING.md`](../Documentation/SESSION_SCOPING.md) |

## WebSocket schema fixtures

- Canonical files live under [`schemas/ws/`](./schemas/ws/) (see also [`fixtures/`](./schemas/ws/fixtures/)).
- **CI / local:** `swift test --filter WebSocketSchemaFixtureTests` ensures fixtures stay aligned with server-side harness control validation (no Node.js required).
- Optional shell helper: [`scripts/validate-ws-schemas.sh`](./scripts/validate-ws-schemas.sh) (documentation only; manual `ajv-cli` possible).

## Lint (Spectral)

Requires Node.js (`npx`):

```bash
bash SileniaAIServer/openapi/scripts/validate-openapi.sh
```

Rules live in [`.spectral.yaml`](./.spectral.yaml). CI runs the same command on pull requests (`.github/workflows/openapi.yml`).

## Swift OpenAPI Generator

The **`SileniaAIClient`** target uses Apple’s [swift-openapi-generator](https://github.com/apple/swift-openapi-generator) as a Swift Package **plugin**. Configuration:

- [`Sources/SileniaAIClient/openapi-generator-config.yaml`](../Sources/SileniaAIClient/openapi-generator-config.yaml)
- OpenAPI document: symlink [`Sources/SileniaAIClient/openapi.yaml`](../Sources/SileniaAIClient/openapi.yaml) → **this directory’s** `openapi.yaml` (edit canonical spec here only; never hand-edit the client link target).

Generated **`Client`**, **`Types`**, and **`Server`** stubs appear under `.build/plugins/outputs/.../OpenAPIGenerator/GeneratedSources` at build time — **do not commit** them.

### Canonical source invariants

- REST canonical source: [`openapi/openapi.yaml`](./openapi.yaml)
- WS canonical source: [`openapi/schemas/ws/`](./schemas/ws/)
- Runtime packaged WS schema mirror: [`Sources/SileniaAIServer/Resources/WSSchemas/`](../Sources/SileniaAIServer/Resources/WSSchemas/)
- Generated Swift WS bindings: [`Sources/SileniaAIClient/Generated/WebSocketSchemaBindings.swift`](../Sources/SileniaAIClient/Generated/WebSocketSchemaBindings.swift)
- Generated Python client bindings: [`openapi/generated/python/`](./generated/python/)

Use the deterministic sync/generation entrypoint:

```bash
bash SileniaAIServer/openapi/scripts/validate-generated-bindings.sh
```

This script:
1. Re-links client OpenAPI input to canonical `openapi.yaml`.
2. Syncs runtime packaged WS schemas from canonical `openapi/schemas/ws`.
3. Regenerates Swift WS bindings consumed by `WebSocketSession`.
4. Regenerates Python REST/WS bindings from the same canonical schemas.

### Migrating more REST calls

1. Ensure [`openapi.yaml`](./openapi.yaml) matches the handler (update `info.version` when behavior changes).
2. Run `swift build` and use new `Operations.*` methods from the generated `Client`.
3. Map generated `Components.Schemas.*` to `SileniaAICommon` types where needed (see [`OpenAPIRESTBridge.swift`](../Sources/SileniaAIClient/OpenAPIRESTBridge.swift)).

## Breaking-change detection (optional)

Install [openapi-diff](https://github.com/OpenAPITools/openapi-diff) or similar locally and compare `openapi.yaml` against `main` before merging large contract edits. Not wired in CI by default.
