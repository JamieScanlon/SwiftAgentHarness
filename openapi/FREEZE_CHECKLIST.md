# Phase 6 freeze checklist (schema / codegen gates)

Use this before treating OpenAPI / AsyncAPI / generated Swift as **stable contracts**.

## Wave decision

| Wave | Scope | Status |
|------|--------|--------|
| **Wave A** | HTTP control plane — OpenAPI + Spectral + `swift-openapi-generator` for [`SileniaAIClient`](../Sources/SileniaAIClient/) | **Active** — implemented artifacts live under [`openapi/`](./). |
| **Wave B** | WebSocket data plane — JSON Schemas + AsyncAPI adjunct for `/ws` harness envelopes | [`schemas/ws/`](./schemas/ws/) + [`asyncapi.yaml`](./asyncapi.yaml). **Inbound** harness control (`kind` subscribe / unsubscribe / **ack**) is **runtime-validated** in [`APILayer`](../Sources/SileniaAIServer/API/APILayer.swift) against [`comm-client-control.schema.json`](./schemas/ws/comm-client-control.schema.json). Fixture parity: `swift test --filter WebSocketSchemaFixtureTests`. Optional outbound soak: `SAH_WS_VALIDATE_OUTBOUND`. |

## Gates

1. **REST paths** — All `/api` routes match [`APILayerRESTModules.swift`](../Sources/SileniaAIServer/API/APILayerRESTModules.swift) and prose in [`ARCHITECTURE.md`](../Sources/SileniaAIServer/API/ARCHITECTURE.md). Breaking path or method changes require OpenAPI `info.version` bump + changelog.
2. **Shared DTOs** — Types in `SileniaAICommon` used on the wire are either frozen for **v1** or versioned in schema (`components/schemas`).
3. **Date encoding** — Known inconsistency: `GET /api/conversations/:id` uses ISO-8601 for dates; list routes may use numeric timestamps (see ARCHITECTURE). Document per-response in OpenAPI `description` until unified.
4. **Errors** — Many failures return `{"type":"error","message":"..."}`; align documented status codes with handlers.
5. **WS envelopes** — [`CommResourceTopicMessage`](../Sources/SileniaAIServer/Communication/ModelWireModels.swift) / topic payloads — sibling schemas under [`schemas/ws/`](./schemas/ws/) document **`value`** shapes (pool health, model state, registries, conversation state, …). **`contentDelta`** + [`model-content-delta-wire.schema.json`](./schemas/ws/model-content-delta-wire.schema.json). Inbound control schema is enforced at runtime; full JSON Schema validation of every outbound **value** is optional (development soak).
6. **Canonical REST input link** — [`Sources/SileniaAIClient/openapi.yaml`](../Sources/SileniaAIClient/openapi.yaml) must stay a symlink to [`openapi/openapi.yaml`](./openapi.yaml). Drift is blocked by `openapi/scripts/validate-generated-bindings.sh` + CI workflow `openapi.yml`.
7. **WS authored vs packaged parity** — [`openapi/schemas/ws/*.schema.json`](./schemas/ws/) is the authored source; [`Sources/SileniaAIServer/Resources/WSSchemas/*.schema.json`](../Sources/SileniaAIServer/Resources/WSSchemas/) is generated mirror output. Checksums must match after sync.
8. **Generated multi-client bindings reproducibility** — Regenerating (`validate-generated-bindings.sh`) must produce no repo drift for:
   - `Sources/SileniaAIClient/Generated/WebSocketSchemaBindings.swift`
   - `openapi/generated/python/`
   - `Sources/SileniaAIServer/Resources/WSSchemas/`

## Open questions (from migration doc)

Record decisions in [`COMMUNICATION_LAYER_MIGRATION.md`](../Documentation/COMMUNICATION_LAYER_MIGRATION.md) when resolved:

- Resume tokens vs raw `seq` for subscribers.
- Replay window sizes per topic class.
- Authorization at connection vs subscribe time.

Until decided, schemas may use **description-only** notes without enforcing behavior.
