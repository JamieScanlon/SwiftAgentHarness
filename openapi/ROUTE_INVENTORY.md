# REST route inventory (`/api`)

Source: [`APILayerRESTModules.swift`](../Sources/SileniaAIServer/API/APILayerRESTModules.swift). Group prefix: **`/api`** (see [`APILayer.swift`](../Sources/SileniaAIServer/API/APILayer.swift)).

## Known wire inconsistencies

| Topic | Detail |
|-------|--------|
| **Dates** | `GET /api/conversations/:id` uses `JSONEncoder.dateEncodingStrategy = .iso8601`. `GET /api/conversations` (list) uses default `JSONEncoder` date encoding (often numeric). Clients cannot assume one rule for all JSON bodies — see [`ARCHITECTURE.md`](../Sources/SileniaAIServer/API/ARCHITECTURE.md). |
| **Errors** | Common JSON: `{"type":"error","message":"..."}`. Some routes return plain text bodies on failure. |
| **HTTP Preconditions** | Key reads emit strong `ETag` and support `If-None-Match -> 304`. Guarded mutations accept `If-Match`; mismatches return `412` and strict-mode missing headers return `428`. |
| **Compaction routes** | `POST .../preview-context-compaction` and `POST .../compact` require header `X-SAH-Context-Compaction-Preview-Token` when configured; may return 404 when disabled. |
| **Trigger ingress boundary** | Trigger API ingress routes are removed from this contract surface. External entities should flow through a trigger gate (idempotency/rate-limit/auth/cost checks) before runtime dispatch. |

## Active routes

| Method | Path | Request body / query | Success response (shape) |
|--------|------|----------------------|---------------------------|
| GET | `/api/status` | — | `{ status, sessions }` |
| GET | `/api/system_prompt/full` | query `userSystemPrompt?` | `{ fullSystemPrompt }` |
| GET | `/api/models` | Optional `If-None-Match` | `{ models: ModelInfo[] }` (ETag / 304 supported) |
| POST | `/api/models/query` | `{ modelRef? \| modelID? \| idOrQuery? }` + optional `If-None-Match` | `{ matches: ModelInfo[] }` (ETag / 304 supported) |
| GET | `/api/conversations` | Optional query: `limit`, `offset`, `search`, `lifecycle`, `sort`, `includeArchived`, `includeDeleted`, `updatedAfter`, `updatedBefore`, `summary`, `owner`, `parentConversationID` | Always **`PagedConversationsResponse`** (`items`, `totalCount`, `nextOffset`) with **`ConversationListSummary`** rows |
| POST | `/api/conversations` | `ConvoRequest` (supports optional `modeProfileID`) | `200 { type:"create", conversationID }` or `400 { type:"error", message }` |
| GET | `/api/conversations/:id` | query `includeDerived?` | `ModelConversation` (ISO8601 dates) |
| PATCH | `/api/conversations/:id` | **`ConversationPatch`** (+ optional `modeProfileID`) + optional `If-Match` | **200** `ConversationPatchResponse` (`type`, `controlPlaneRevision`) / **409** conflict JSON / strict precondition **412/428** / structured `type:error` for **400/404** |
| DELETE | `/api/conversations/:id` | Query: optional `hard` (default **true**; `hard=false` soft-deletes); optional `If-Match` in strict mode | `200` / `404` error JSON / strict precondition `412` or `428` |
| GET | `/api/conversations/:id/events` | query `since?`; optional `If-None-Match` | `ConversationEventsBackfillResponse` (`conversationID`, `since`, `latestSeq`, `lagging`, `events`) |
| POST | `/api/conversations/:id/messages` | `ChatRequest` (conversation inferred from path) | Canonical send route returning **`201`** `AppendInputResponse` (`runId`, `messageId`); no `/append-input` alias |
| POST | `/api/conversations/:id/revert` | `ConversationRevertRequest` + optional `If-Match` | Canonical in-place revert stream route; strict precondition **412/428** |
| POST | `/api/conversations/:id/branch` | `ConversationBranchRequest` + optional `If-Match` | Canonical split route (`ConversationBranchResponse`); strict precondition **412/428** |
| POST | `/api/conversations/:id/cancel` | `CancelConversationRunRequest` (`runId`), optional `If-Match` | **`200`** `CancelConversationRunResponse` on accepted/idempotent cancel; **`409`** `CancelConversationRunConflictBody` when not in flight or already ended |
| POST | `/api/conversations/:id/tool-approvals` | `ToolApprovalResolutionRequest` | `200` or structured `type:error` (`400/404/501`) |
| POST | `/api/conversations/:id/completion-announcements` | `CompletionAnnounceTriggerRequest` | `CompletionAnnounceTriggerResponse` or structured `type:error` (`400/404/501`) |
| POST | `/api/conversations/:id/projection` | projection request body | Projected messages + metadata JSON |
| GET | `/api/conversations/:id/plan` | — | `{ markdown }` |
| GET | `/api/conversations/:id/slash-commands` | — | `[SlashCommandAutocompleteEntry]` |
| GET | `/api/conversations/:id/server-metadata` | — | `ConversationServerMetadata` |
| POST | `/api/conversations/:id/preview-context-compaction` | optional preview flags + debug path | Preview compaction JSON |
| POST | `/api/conversations/:id/compact` | optional `{ reason }` | Manual compaction JSON |
| POST | `/api/conversations/:id/checkpoints` | `ConversationCheckpointInvalidateRequest` | Canonical checkpoint invalidation mutation |
| GET | `/api/conversations/:id/checkpoints/latest` | query `kind?` (`context_compaction`, `memory_injection_snapshot`, `tool_result_trim`, `system_prompt_assembly`) | Latest valid checkpoint wire JSON for requested kind (default: `context_compaction`) or **404** |
| GET | `/api/conversations/:id/runs` | query `limit?`; optional `If-None-Match` | **`ConversationRunListResponse`** (`304` on matching validator) |
| GET | `/api/conversations/:id/runs/:runId` | query **`detail?`** (`1` / `true` / `yes` → **`projectionDetail`**); optional `If-None-Match` | **`ConversationRunInfo`** or **404** (`304` on matching validator) |
| POST | `/api/conversations/:id/runs/:runId/cancel` | optional `If-Match` | **`200`** `CancelConversationRunResponse` on accepted/idempotent cancel; **`409`** when not in flight or already ended |
| GET | `/api/conversations/:id/sub-agents/active` | — | Active sub-agent invocation list (`ActiveSubAgentInvocationListResponse`) |
| POST | `/api/conversations/:id/sub-agents/:lifecycleID/cancel` | — | Idempotent sub-agent invocation cancel (`204`) |
| GET | `/api/conversations/:id/engine-artifacts` | — | `EngineArtifactKeysResponse` |
| GET | `/api/conversations/:id/engine-artifacts/:key` | — | Raw artifact bytes (`application/octet-stream`) or **404** |
| PUT | `/api/conversations/:id/engine-artifacts/:key` | raw body + optional `If-Match` | **`204`** on success |
| DELETE | `/api/conversations/:id/engine-artifacts/:key` | optional `If-Match` | **`204`** on success |
| DELETE | `/api/conversations/:id/engine-artifacts` | optional `If-Match` | Bulk delete; **`204`** on success |
| GET | `/api/tools` | Optional `If-None-Match` | Global `AvailableToolInfo[]` registry read (ETag / 304 supported) |
| GET | `/api/skills` | Optional `If-None-Match` | Global `AvailableSkillInfo[]` registry read (ETag / 304 supported) |
| GET | `/api/sub-agents` | Optional `If-None-Match` | Global sub-agent registry rows (`SubAgentRegistryEntry[]`, ETag / 304 supported) |
| GET | `/api/modes` | Optional `If-None-Match` | Global mode profile catalog (`{ profiles: ModeProfileDTO[] }`, ETag / 304 supported) |
| GET | `/api/search` | `q`, `kind`, `limit`, `offset`, optional `owner`, `includeArchived`, `includeDeleted` | `ConversationSearchResponse` |
| GET | `/api/traces/:conversationId` | Optional query `limit` | Conversation trace span set (`ConversationTraceResponse`) |
| POST | `/api/upload` | multipart body + `X-File-Name`, `Content-Type` | `{ filename, size, contentType, filePath }` |

## Removed routes (404)

Unregistered legacy paths return **`404` not found**. Use the replacement in the third column.

| Method | Path | Replacement / notes |
|--------|------|------------------------|
| GET | `/api/conversations/select/:id` | Explicit `GET /api/conversations/:id` + WS topic subscriptions |
| GET | `/api/conversations/search` | `GET /api/search` |
| GET | `/api/conversations/:id/orchestration-state` | WS `conversation/{id}/state` |
| GET | `/api/conversations/:id/turn-state` | WS `conversation/{id}/state` |
| GET | `/api/conversations/:id/available-tools` | Removed; use `GET /api/conversations/:id/tools` |
| GET | `/api/conversations/:id/tools` | Effective `AvailableToolInfo[]` for the conversation (mode profile, routing whitelist, disabled tools) |
| GET | `/api/tools` | Global registered `AvailableToolInfo[]` catalog (unfiltered; ETag / 304 supported) |
| GET | `/api/conversations/:id/available-skills` | Removed; use `GET /api/conversations/:id/skills` |
| GET | `/api/conversations/:id/skills` | Effective `AvailableSkillInfo[]` for the conversation (mode profile, routing whitelist, disabled skills) |
| GET | `/api/skills` | Global `AvailableSkillInfo[]` registry read (ETag / 304 supported) |
| PUT | `/api/conversations/:id/metadata` | `PATCH /api/conversations/:id` |
| PUT | `/api/conversations/:id/model-and-prompt` | `PATCH /api/conversations/:id` |
| PUT | `/api/conversations/:id/tool-overrides` | `PATCH /api/conversations/:id` + `ConversationPatch.disabledToolNames` |
| PUT | `/api/conversations/:id/skill-overrides` | `PATCH /api/conversations/:id` + `ConversationPatch.disabledSkillNames` |
| PUT | `/api/conversations/:id/thinking-preference` | `PATCH /api/conversations/:id` + `ConversationPatch.routingModelOptions.thinkingConfig` |
| PUT | `/api/conversations/:id/reasoning-effort` | `PATCH /api/conversations/:id` + `ConversationPatch.routingModelOptions.thinkingConfig` |
| POST | `/api/conversations/copy` | Not on canonical HTTP control-plane contract (internal host API only) |
| POST | `/api/conversations/:id/append-input` | `POST /api/conversations/:id/messages` |
| POST | `/api/conversations/:id/messages/trigger` | Trigger-gate ingress (non-API) |
| POST | `/api/conversations/:id/sub-agents` | Sub-agent spawn not on canonical HTTP control-plane contract |
| POST | `/api/conversations/:id/checkpoints/invalidate` | `POST /api/conversations/:id/checkpoints` |
| GET | `/api/messages` | `GET /api/conversations/:id` or WS `conversation/{id}/events` |
| POST | `/api/messages` | `POST /api/conversations/:id/messages` |
| POST | `/api/messages/trigger` | Trigger-gate ingress (non-API) |
| POST | `/api/messages/agent_build/stop` | `POST /api/conversations/:id/cancel` |
| POST | `/api/messages/replay/start` | Removed |
| POST | `/api/messages/replay/stop` | Removed |
| GET | `/api/messages/replay/status` | Removed |

Legacy WebSocket **`type`** frames are also removed (rejected at harness control validation). Historical mapping: [`SESSION_SCOPING.md`](../Documentation/SESSION_SCOPING.md), [`ARCHITECTURE.md`](../Sources/SileniaAIServer/API/ARCHITECTURE.md).

## WebSocket

Not REST — see [`asyncapi.yaml`](./asyncapi.yaml) and [`schemas/ws/`](./schemas/ws/). Inbound accepts harness **`kind`** control only (`subscribe`, `unsubscribe`, `ack`, `dedupe_check_and_set`); legacy client **`type`** frames are rejected during validation.
