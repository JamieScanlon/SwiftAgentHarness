# REST route inventory

Machine-readable tenancy guard matrix: [`route-tenancy-inventory.json`](./route-tenancy-inventory.json).

Human-readable request/response shapes and removed-route tombstones remain in [OpenAPI 3.1](./openapi.yaml) and [ARCHITECTURE.md](../Sources/SwiftAgentHarness/Core/CommunicationLayer/API/ARCHITECTURE.md).

## Tenancy guard taxonomy

REST tenancy is **discipline-based**: handlers call helpers from `APILayerTenancy.swift` rather than relying on middleware or an address-scoped query layer. That is acceptable for the multi-user deployment model, but every new route is a site where the call can be forgotten.

| `tenancy_guard` | Required helper call(s) | Typical routes |
|---|---|---|
| `conversationAccess` | `tenancyRespondIfConversationAccessForbidden` or `tenancyEnsureConversationTenant` | `GET/POST/PATCH/DELETE` under `/api/conversations/{id}/…` |
| `createMutation` | `tenancyRespondIfCreateMutationForbidden` or `tenancyEnsureAuthenticatedOwnerForMutation` | `POST /api/conversations` |
| `collectionScope` | `tenancyResolveCollectionOwnerScope` | `GET /api/conversations`, `GET /api/search` |
| `none` | (no tenancy helper in the handler region) | Global reads: status, models, registries, upload, exec-approval grants |

When a route delegates to a static helper (for example `sendMessageResponse` or `resolveExecApprovalViaREST`), the inventory `handler_anchor` points at that helper so the invariant test checks the callee that owns the guard.

## WebSocket subscribe authorization (out of scope for REST inventory v1)

Harness WebSocket topics use [`WebSocketTopicSubscribeAuthorization`](../Sources/SwiftAgentHarness/Core/CommunicationLayer/WebSocketTopicSubscribeAuthorization.swift) (`deniedReasonFor*`) at subscribe time, not the REST `tenancyRespondIf*` helpers. WS topics are documented in [ARCHITECTURE.md](../Sources/SwiftAgentHarness/Core/CommunicationLayer/API/ARCHITECTURE.md) and [asyncapi.yaml](./asyncapi.yaml); they are not yet enforced by the REST route inventory invariant.

## Adding or changing a REST route

1. Register the handler in `APILayerRESTModules.swift` (or `APILayer.swift` for top-level list routes).
2. Add or update an entry in [`route-tenancy-inventory.json`](./route-tenancy-inventory.json) with `method`, `path`, `tenancy_guard`, `source_file`, and `handler_anchor`.
3. Ensure `APILayerTenancyGuardInvariantTests` passes (`swift test --filter APILayerTenancyGuardInvariantTests`).
4. Update [openapi.yaml](./openapi.yaml) when the wire contract changes.

## Invariant test limitations

- **Anchor fragility:** Renaming a route registration or moving a handler requires updating `handler_anchor` in the JSON inventory.
- **Delegated guards:** If the guard lives in a callee, `handler_anchor` must name that callee (not only the route closure).
- **Exempt routes:** Mark `tenancy_guard: none` only for handlers that are truly global; the invariant fails if an exempt handler region contains any tenancy helper substring.

## Removed routes (404 tombstones)

These paths are intentionally retired; clients should use the replacement noted in OpenAPI / ARCHITECTURE:

- `GET /api/conversations/select/{id}` — removed
- `PUT /api/conversations/{id}/metadata` — use `PATCH /api/conversations/{id}`
- `PUT /api/conversations/{id}/tool-overrides` — use `PATCH /api/conversations/{id}`
- `PUT /api/conversations/{id}/skill-overrides` — use `PATCH /api/conversations/{id}`
- `PUT /api/conversations/{id}/thinking-preference` — use `PATCH /api/conversations/{id}`
- `PUT /api/conversations/{id}/reasoning-effort` — use `PATCH /api/conversations/{id}`
- `POST /api/conversations/{id}/checkpoints/invalidate` — use `POST /api/conversations/{id}/checkpoints`
