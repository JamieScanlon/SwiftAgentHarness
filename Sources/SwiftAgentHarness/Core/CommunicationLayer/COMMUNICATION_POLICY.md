# Communication Layer policy

Implementation lives under this folder; the HTTP gateway ([`APILayer`](../API/APILayer.swift)) forwards bytes and does not redefine topic rules here.

---

## 1. Authorization and trust

### Today

- **`/ws`** uses the same trust model as the rest of the server process: there is **no separate auth gate** at WebSocket upgrade beyond whatever the deployment puts in front of Vapor.
- **Subscribe-time authorization** for multiplexed harness topics is enforced in [`WebSocketTopicSubscriptionRouter`](WebSocketTopicSubscriptionRouter.swift) via [`WebSocketTopicSubscribeAuthorization`](WebSocketTopicSubscribeAuthorization.swift):
  - **`conversation/{id}/events`** and **`conversation/{id}/state`**: requires `apiGetConversation(id)` to succeed; when [`APILayerConversationManaging/apiRegistryOwnerAccountID()`](../API/APILayer.swift) is non-nil (tenant registry scope), the conversation’s **`ownerAccountID`** must match that scope.
  - **`subagent/{conversationId}/{path}/events`** and **`subagent/{conversationId}/{path}/state`**: same rules applied to parsed **`conversationId`**.
  - **`trace/{conversationId}`**: same conversation visibility/tenancy check as other conversation-scoped topics.
  - **`trace/server`**: process-wide observability stream. Operator-scoped by default (`ServerConfig/enforceOperatorForServerTraceSubscribe`, default **`true`**); subscribe requires a validated **`Authorization: Bearer`** JWT whose `sub` claim matches an entry in ``ServerConfig/serverTraceOperatorOwnerIDs``. Also auto-engaged when ``requireAuthenticatedTenantOnAPI`` is true. Set ``enforceOperatorForServerTraceSubscribe`` to **`false`** for single-tenant open subscribe.
  - **`pool/health`**: same operator allowlist as **`trace/server`** (admin-scoped observability).
  - **`model/{id}/state`**: **`modelID`** must appear in the session **`getAvailableModels()`** catalog (same set as **`GET /api/models`** / **`models/registry`** snapshot).
  - **Models registry** and **session capability registries** (`tools/registry`, etc.) are not gated by operator checks (see policy table intent in implementation comments).
- **Mutation-time and collection-read tenancy (REST + WebSocket + model tools):** When strict authenticated tenancy is enabled (`TenancyPolicySettings.requireAuthenticatedOwnerOnMutations`), inbound REST handlers and mutating WebSocket frames require a resolved **`APISessionContext.authenticatedOwnerAccountID`** from a validated **`Authorization: Bearer`** harness access JWT (`sub` = owner UUID) and verify it against the persisted conversation’s **`ownerAccountID`** for the targeted conversation id. Collection reads **`GET /api/conversations`**, **`GET /api/search`**, and model-tool **`list_conversations`** auto-scope to the authenticated owner under strict tenancy ( **`401`** without a valid token; **`403`** when an explicit **`owner=`** query param mismatches the JWT `sub`). The legacy **`X-SAH-Authenticated-Owner`** header is **ignored**. This complements subscribe-time checks above; keep the same Bearer token on **`/api`** and **`/ws`** upgrade for the same principal.
- **Durable tool approval grants (SEC-011 / DEF-122):** `allow-always` tool rules persisted via **`POST …/tool-approvals`** with **`durable: true`** are keyed by the conversation owner’s **`ownerAccountID`**, not globally by tool name. Under strict tenancy, only owner-scoped grants apply to that owner’s conversations; legacy process-wide **`.toolName`** rules in the permission store are ignored. Single-tenant deployments without owner ids may still use legacy global **`.toolName`** grants when strict tenancy is off.
- **Memory partition under strict tenancy:** Conversations and approvals are owner-scoped; agent-written memory is too. When `requireAuthenticatedOwnerOnMutations` is true, project and user memory directories are resolved under `<configHome>/owners/<ownerUUID>/…` (see [`Core/Memory/README.md`](../Memory/README.md)). Memory is per-owner-per-workspace, not workspace-global — private-conversation extraction cannot land in another owner’s recall/injection path. Legacy unscoped memory under `<configHome>/projects/` is not read after enabling strict tenancy (no auto-migration).
- **Response cache partition under strict tenancy:** The Model Pool in-process response cache (`ResponseCachingLLM`) prefixes cache keys with the conversation owner when `requireAuthenticatedOwnerOnMutations` is true (see [`Core/ModelPool/README.md`](../ModelPool/README.md)). Identical prompts across owners cannot return a cached completion from another owner's prior call. Cache is bypassed when strict tenancy is on but no owner is resolved.
- **Budget / scheduler / fan-out partition under strict tenancy:** Per-account spend caps (`maxUSDPerAccount`, defaulting to per-conversation when unset), model-call scheduler in-flight and rate buckets (`ModelCallScheduler` / `SchedulingLLM`), and sub-agent lane fan-out (`RuntimeLaneCoordinator`) are partitioned by owner so one user's load cannot exhaust the shared process pool. See [`Core/ModelPool/README.md`](../ModelPool/README.md).
- **Embedded host mutations:** CLI / in-process hosts must mutate through [`EmbeddedHarnessAPIClient`](API/EmbeddedHarnessAPIClient.swift) loopback (same REST handler pipeline as socket clients), not by calling `HarnessRuntimeSession` service methods directly, when wire-equivalent policy (tenancy, `If-Match`, session namespace) must hold. Subscribe remains via embedded topic seams on ``CommunicationLayer``.
- Failed authorization returns **`{"kind":"error","message":"Subscribe denied"}`** (stable message); deployment-owned logging may capture detail.

### Strict tenancy scope (authorization, not isolation)

**Strict authenticated tenancy is an authorization feature, not an isolation boundary.** Owner checks on REST, WebSocket subscribe, model tools, memory paths, caches, and budgets prevent *accidental* cross-owner access through the wire API and keyed subsystems — they do not sandbox the process. Execution environments, the on-disk conversation catalog and transcripts, session blob stores, and the Vapor process itself remain shared across owners on a single instance. An owner whose conversations can invoke filesystem or shell tools can, in principle, read or modify another owner's persisted data on the same host. That is inherent to the **multi-user within one trusted org** posture (users trust the operator and broadly each other). For **mutually untrusting** tenants, run **instance-per-tenant** (or stronger OS/VM isolation) rather than relying on strict tenancy alone; see [multi-tenant-deployment.md](../../../../harness-template/core/multi-tenant-deployment.md).

### Connection-time identity

Authenticated tenancy uses **`Authorization: Bearer <JWT>`** on REST (`ClientSessionMiddleware`) and WebSocket upgrade (`/ws`). Tokens are HS256 JWTs verified with ``ServerConfig/apiAccessTokenHS256Secret``; the owner principal is the JWT **`sub`** claim (UUID string). When ``requireAuthenticatedTenantOnAPI`` is enabled, ``APILayer/start()`` fails closed unless a validator secret is configured. Deployments must strip client-origin **`Authorization`** (and legacy **`X-SAH-Authenticated-Owner`**) at the reverse proxy and inject a short-lived harness JWT minted after IdP/session validation.

TLS/session identity at upgrade remains deployment-owned; topic checks above complement but do not replace perimeter controls.

### Harness control frames (`kind`)

- **Inbound:** Multiplexed control uses [`CommClientControlMessage`](ModelWireModels.swift): **`subscribe`**, **`unsubscribe`**, **`ack`**, and **`dedupe_check_and_set`**. Before Codable decode, [`WebSocketCommClientControlValidator`](WebSocketCommClientControlValidator.swift) enforces the same shape as [`comm-client-control.schema.json`](../../../openapi/schemas/ws/comm-client-control.schema.json). Allowed keys include **`kind`**, **`topic`**, **`since`**, **`sinceMessageSeq`**, **`sinceCheckpointSeq`**, **`resumeToken`** (for `subscribe`), **`upTo`** (for `ack`), **`dedupeKey`**, **`dedupeTtlSeconds`** (for `dedupe_check_and_set`); no extras. Validation and routing failures return **`{"kind":"error","message":"..."}`**. Successful dedupe returns **`{"kind":"dedupe_result","firstSighting":true|false}`**.
- **Interim `type:` request frames** (non-`kind` chat/control messages) are not schema-validated at the boundary; they exist only until the **client** uses HTTP + topic **`kind`** control for all operations and this path is deleted server-side.
- **Outbound runtime enforcement:** harness topic envelopes are typed-validated once at encode into [`HarnessOutboundWireLine`](HarnessOutboundWireLine.swift) before websocket send. Optional env-gated full JSON re-validation: `SAH_WS_VALIDATE_OUTBOUND=1`.
- **Publishing governance (default strict):** Conversation and registry topic hubs apply publish-time contract validation via [`PublishingContractValidator`](PublishingContractValidator.swift). `strict` rejects invalid publishes; `soft` emits diagnostics and still publishes. Configuration loads from `PromptConfig.json` (`publishingGovernance`) with optional composition-root overrides (`ServerConfig`).

---

## 2. Topic classes

| Topic pattern | Hub | Payload types |
|---------------|-----|----------------|
| `model/{uuid}/state` | [`ModelStateTopicHub`](ModelStateTopicHub.swift) | [`ModelStatePayload`](ModelWireModels.swift) |
| `model/{uuid}/calls` | [`ModelStateTopicHub`](ModelStateTopicHub.swift) | [`ModelCallsPayload`](ModelWireModels.swift) |
| `pool/health` | [`ModelStateTopicHub`](ModelStateTopicHub.swift) | [`PoolHealthPayload`](ModelWireModels.swift) |
| `models/registry` | [`ModelStateTopicHub`](ModelStateTopicHub.swift) | [`ModelsRegistryPayload`](ModelWireModels.swift) |
| `conversation/{uuid}/events` | [`ConversationEventsTopicHub`](ConversationEventsTopicHub.swift) | [`ConversationTopicEventPayload`](ModelWireModels.swift) |
| `conversation/{uuid}/state` | [`ConversationStateTopicHub`](ConversationStateTopicHub.swift) | [`ConversationStatePayload`](ModelWireModels.swift) |
| `tools/registry` | [`CapabilityRegistryTopicHub`](CapabilityRegistryTopicHub.swift) | [`ToolsRegistryPayload`](ModelWireModels.swift) |
| `skills/registry` | [`CapabilityRegistryTopicHub`](CapabilityRegistryTopicHub.swift) | [`SkillsRegistryPayload`](ModelWireModels.swift) |
| `sub-agents/registry` | [`CapabilityRegistryTopicHub`](CapabilityRegistryTopicHub.swift) | [`SubAgentsRegistryPayload`](ModelWireModels.swift) |
| `conversations/registry` | [`ConversationsRegistryTopicHub`](ConversationsRegistryTopicHub.swift) | [`ConversationsRegistryPayload`](ModelWireModels.swift) |
| `subagent/{conversationId}/{path}/events` | [`SubAgentLifecycleTopicHub`](SubAgentLifecycleTopicHub.swift) | [`SubAgentLifecycleTopicPayload`](ModelWireModels.swift) |
| `subagent/{conversationId}/{path}/state` | [`SubAgentLifecycleTopicHub`](SubAgentLifecycleTopicHub.swift) | [`SubAgentLifecycleTopicPayload`](ModelWireModels.swift) |
| `trace/{conversationId}` | [`TraceTopicHub`](TraceTopicHub.swift) | [`TraceTopicPayload`](ModelWireModels.swift) |
| `trace/server` | [`TraceTopicHub`](TraceTopicHub.swift) | [`TraceTopicPayload`](ModelWireModels.swift) |

Control-plane subscribe/unsubscribe uses [`CommClientControlMessage`](ModelWireModels.swift); routing policy lives in [`WebSocketTopicSubscriptionRouter`](WebSocketTopicSubscriptionRouter.swift).

**Session capability topics:** `tools/registry`, `skills/registry`, and `sub-agents/registry` reflect the explicit subscribe control-frame `conversationId` context. `sub-agents/registry` is now **schema v2**: canonical AgentEntry-like rows in `entries` plus compatibility delegate tool rows in `agents`.

---

## 3. Sequence numbers (`seq`), `lagging`, and replay

### Wire seq invariant (conversation/{id}/events)

The harness-style model distinguishes **three classes** of traffic on **`conversation/{id}/events`**:

1. **Persisted message** — durable transcript work (e.g. user/assistant message-shaped envelopes). Envelope **`seq`** is now the live transport ordering cursor. Persisted replay anchors remain transcript-backed via **`messageSeq`**.

2. **Persisted checkpoint** — durable checkpoint / compaction-style rows in the **same** per-conversation monotonic sequence (v2 SQLite / JSONL). **`checkpointSeq`** remains transcript-backed for replay anchoring.

3. **Transient progress** — run-scoped streaming (token deltas, tight loops, in-flight tool lifecycle): **not** persisted as transcript rows. These frames now carry envelope-level **`seq`** plus **`runId`** / **`turnOrdinal`** correlation metadata, but replay remains persisted-only.

**Implementation status (P2):** **Done.** Envelope-level **`seq`** is emitted for persisted and transient conversation events. Persisted replay anchors remain transcript-backed via **`messageSeq`** / **`checkpointSeq`**. Subscribe catch-up still replays **persisted** rows via [`ConversationEventsTranscriptReplayHydrator`](ConversationEventsTranscriptReplayHydrator.swift) over **`readTranscriptEntries`**; transient lines remain live-only. Runtime/transient correlation continues to use **`runId`** + hub-issued **`turnOrdinal`**, with optional nested **`callId`** inside [`ModelContentDeltaWire`](ModelContentDeltaWire.swift).

### Per-topic monotonic `seq`

- For **most** topics, each **topic string** has an independent counter in **`seqByTopic`** inside the hub actors.
- For **`conversation/{id}/events`**: all envelopes carry top-level **`seq`**. Persisted replay anchors remain on **`messageSeq`** / **`checkpointSeq`**.
- **`nextSeq(for:)`** (non-conversation hubs) assigns the next integer on every **snapshot** sent at subscribe time and every **`event`** (broadcast) for that topic.
- Clients may send **`since`** on subscribe (`CommClientControlMessage.since`) for **`conversation/{id}/events`** as a legacy persisted replay cursor. Dual cursors (`sinceMessageSeq` / `sinceCheckpointSeq`) are the canonical persisted replay anchors.

### `lagging` envelope

- **`lagging`** is sent **before** the subscribe-time **`snapshot`** when catch-up is requested **and** the server **cannot** satisfy **persisted** replay. On **`conversation/{id}/events`**, that includes transcript hydration gaps or dual cursor values ahead of store-derived heads.
- For **non-conversation** topics: when the ring cannot replay contiguous **`seq`**, or **`since > latestSeq`**.
- When contiguous **persisted** rows exist for the requested range, the server **replays** those **`event`** lines first and **omits** **`lagging`**.
- Payload shape: [`CommResourceTopicMessage`](ModelWireModels.swift) with `kind: lagging`, same `topic`, `seq` set to **latest persisted head** (transcript / snapshot cursor for conversation events), `hint: "resync"`.
- Meaning: the client may have missed **persisted** envelopes; treat the following **`snapshot`** as authoritative.

### Replay window

- **Non-`conversation/{id}/events`** hubs retain a **bounded, in-memory ring** ([`TopicReplayStore`](TopicReplayBuffer.swift)); retention from [`TopicReplayCapacityConfiguration`](TopicReplayBuffer.swift) / [`ServerConfig.topicReplayCapacities`](../API/ServerConfig.swift). **`snapshot`** handshakes are **not** buffered for replay.
- **`conversation/{id}/events`**: **persisted** replay is **authoritative** from **`readTranscriptEntries`** via [`ConversationEventsTranscriptReplayHydrator`](ConversationEventsTranscriptReplayHydrator.swift). **Transient** lines are still **live-only**.
- **`since`** (conversation events, single-cursor mode): last processed **transcript `sequence`** for persisted total-order replay (matches envelope **`seq`** on persisted **`event`** lines).
- **Dual cursors** **`sinceMessageSeq`** / **`sinceCheckpointSeq`**: replay **transcript rows** classified by [`ConversationEventsReplayClassifier`](ConversationEventsReplayClassifier.swift). **Persisted** **`event`** lines carry **`messageSeq`** / **`checkpointSeq`** as appropriate; transient lines still carry `runId` / `turnOrdinal` correlation metadata.
- **`resumeToken`**: HMAC cursor ([`ConversationEventsResumeToken`](ConversationEventsResumeToken.swift)); **`tot`** should align with **persisted** head. Requires [`ServerConfig.websocketResumeTokenHMACSecret`](../API/ServerConfig.swift). Mutually exclusive with **`since`** / dual-seq on subscribe (see [`WebSocketTopicSubscriptionRouter`](WebSocketTopicSubscriptionRouter.swift)). When configured, the server **mints** a fresh token on **`conversation/{id}/events`** subscribe handshake (**`lagging`** / **`snapshot`** outbound envelopes carry optional **`resumeToken`**).

### Query helpers

- [`ModelStateTopicHub.currentSeq(forModelID:)`](ModelStateTopicHub.swift)
- [`ConversationEventsTopicHub.currentSeq(forConversationID:)`](ConversationEventsTopicHub.swift) (last envelope-level wire `seq` observed for the topic)
- [`ConversationEventsTopicHub.currentMessageSeq(forConversationID:)`](ConversationEventsTopicHub.swift) (last **persisted** message-stream **sequence**)
- [`ConversationEventsTopicHub.currentCheckpointSeq(forConversationID:)`](ConversationEventsTopicHub.swift) (last **persisted** checkpoint-stream **sequence**)
- [`ConversationStateTopicHub.currentSeq(forConversationID:)`](ConversationStateTopicHub.swift)
- [`CapabilityRegistryTopicHub.currentSeq(forTopic:)`](CapabilityRegistryTopicHub.swift) for `tools/registry`, `skills/registry`, `sub-agents/registry`
- [`SubAgentLifecycleTopicHub.currentSeq(forTopic:)`](SubAgentLifecycleTopicHub.swift) for `subagent/{conversationId}/{path}/{events|state}`
- [`TraceTopicHub.currentSeq(forTopic:)`](TraceTopicHub.swift) for `trace/{conversationId}` and `trace/server`
- [`ConversationsRegistryTopicHub.currentSeq(forTopic:)`](ConversationsRegistryTopicHub.swift) for `conversations/registry`

---

## 4. Harness outbound envelopes

Server outbound frames are harness-shaped only. Data-plane topic traffic uses **`CommResourceTopicMessage`** (`snapshot` \| `event` \| `lagging`) per subscribed topic, and control responses use top-level **`kind`** (`error`, `dedupe_result`).

All topic envelopes now carry canonical trust tags:
- **`trustClass`**: effective enforcement floor for the frame (`trusted` or `restricted`).
- **`originTrust`**: provenance class (`system`, `user-direct`, `user-deferred`, `known-party`, `unknown-party`).

`trustClass` is computed as the most restrictive class represented by envelope content where topic-specific provenance exists (for example sub-agent lifecycle/registry payload trust levels); otherwise the publisher applies the topic-safe floor.

### Mapping matrix

| Legacy shape removed | Harness topic stream | Notes |
|---------------------|----------------------|--------|
| `type:messages` | `ConversationTopicEventPayload.semanticKind == messagesRefresh` | Same row JSON projection is preserved in topic payloads. |
| `type:partial` | `contentDelta` (`jsonUTF8` encodes [`ModelContentDeltaWire`](ModelContentDeltaWire.swift)) | Includes `text`, `reasoning`, and `toolCall` deltas. |
| `type:done` | `streamDone` | End-of-turn streaming marker on events topic. |
| `type:orchestration_state` | _(removed)_ | Orchestration transitions are now published only on `conversation/{id}/state.orchestration`. |
| _(none previously)_ | `runtimeLifecycle` (`jsonUTF8` encodes `RuntimeLifecycleEventPayload`) | Runtime lifecycle timeline is topic-native. |

Publishing path is consolidated through harness topic publishers (`ConversationTopicPublishing`, `ConversationStatePublishing`) — see [`COMMUNICATION_LAYER_MIGRATION.md`](../../../Documentation/COMMUNICATION_LAYER_MIGRATION.md).

### Ordering during a streaming turn

For one user send, `conversation/{id}/events` ordering is deterministic at the stream-source merge point: streaming fragments (`ChatStreamingPartial`, `text` / `reasoning` / `toolCall`) and runtime lifecycle milestones (`runtimeLifecycle`) are emitted in source order (`turn.started` -> iteration/model/tool milestones -> terminal event). All envelopes carry top-level **`seq`**; conversation-specific correlation remains on **`runId`** + **`turnOrdinal`**.

**Contract:** Top-level **`seq`** is the authoritative topic order for subscribers across both persisted and transient event traffic. `runId` / `turnOrdinal` remain correlation fields for run-scoped UX and diagnostics.

For tool lifecycle milestones carried in `runtimeLifecycle`, cross-surface observability joins use the same correlation key contract across topic payloads, derived audit rows, and trace attributes: `runID`, `toolName`, `toolCallID`, with optional `delegateHandleID` and `completionAnnounceID` when applicable. Provenance (`argument*` / `result*`) and execution-environment (`executionEnvironment*`) fields follow the same parity contract for those milestones; adapter ownership remains explicit via `executionEnvironmentAdapterID`.

Tool lifecycle terminality contract: `tool.callStarted` is required when the runtime begins a tool call and must include `toolName` + `toolCallID`. `tool.callCompleted` is best-effort and may be absent on paths that terminate naturally after tool result ingestion; consumers must treat `turn.completed` / `turn.cancelled` / `turn.bounded` as the authoritative turn terminal milestones instead of requiring `tool.callCompleted`.

### `conversation/{id}/state` vs `conversation/{id}/events`

- **`conversation/{id}/events`** carries the **streaming/runtime** timeline (`messagesRefresh`, `contentDelta`, `runtimeLifecycle`, `streamDone`, checkpoint events): all rows carry envelope `seq`; persisted replay anchors remain `messageSeq` / `checkpointSeq`.
- **`conversation/{id}/state`** is the **authoritative** state-transition channel. `ConversationStatePayload.orchestration` is the only supported websocket source for orchestration state transitions.

---

## 5. Aggregates and publishing

- [`CommunicationLayer`](CommunicationLayer.swift) bundles [`modelPoolTopics`](ModelStateTopicHub.swift), [`conversationEvents`](ConversationEventsTopicHub.swift), [`conversationState`](ConversationStateTopicHub.swift), [`traceTopics`](TraceTopicHub.swift), [`subAgentLifecycle`](SubAgentLifecycleTopicHub.swift), capability registries, and conversations registry hubs.
- **Model pool fan-out** (`model/{id}/state`, `pool/health`, `models/registry`) must go through [`ModelPoolResourceTopicPublishing`](ModelPoolResourceTopicPublishing.swift) (production wiring: ``CommunicationLayer``). Composition/runtime code should not wire direct hub publishing closures.
- `model/{id}/state` stays a coalesced derived schedulability projection. Per-attempt failover/retry/substitution plus prompt-cache planning/execution telemetry is carried on append-first `model/{id}/calls` (`ModelCallRecord.attempts` + logical request correlation fields) and mirrored by REST/SSE call-ledger surfaces.
- **Conversation `conversation/{id}/events` fan-out** must go through [`ConversationTopicPublishing`](ConversationTopicPublishing.swift) in API/gateway code (production: ``CommunicationLayer``; tests: ``ConversationEventsHubOnlyPublisher``). Do not call [`ConversationEventsTopicHub`](ConversationEventsTopicHub.swift) `broadcast` directly from route or transport glue—keeps subscribe registration on the actor while publishing stays policy-consistent.
- **`conversation/{id}/state` fan-out** must go through [`ConversationStatePublishing`](ConversationStatePublishing.swift) (production: ``CommunicationLayer``; tests: ``ConversationStateHubOnlyPublisher``). Do not call [`ConversationStateTopicHub`](ConversationStateTopicHub.swift) `broadcast` directly from route glue.
- **Registry fan-out** (`tools/registry`, `skills/registry`, `sub-agents/registry`, `conversations/registry`) must go through facade protocols (`CapabilityRegistryPublishing`, `ConversationsRegistryPublishing`) backed by ``CommunicationLayer`` in production.

### Contract validation discipline

- Central validator: [`PublishingContractValidator`](PublishingContractValidator.swift) enforces semantic payload shape and schema-version invariants for:
  - `conversation/{id}/events` (`ConversationTopicEventPayload` semantic contracts),
  - `conversation/{id}/state` (`ConversationStatePayload.schemaVersion`; **`attachmentsCatalog`** entry shape when present — harness README: state publishes attachment changes),
  - registry topics (`tools/registry`, `skills/registry`, `sub-agents/registry`, `conversations/registry` schema versions).
  - sub-agent lifecycle/state topics (`SubAgentLifecycleTopicPayload` schema version and entry consistency).
- Governance mode:
  - **strict**: drop invalid publish before seq increment (no sequence drift from rejected payloads).
  - **soft**: allow publish while surfacing warning diagnostics for drift (useful during migration; prefer **strict** once payloads stabilize).

---

## 6. Backpressure, `ack`, and outbound flow control

Implementation: [`WebSocketHarnessOutboundFlowLimiter`](WebSocketHarnessOutboundFlowLimiter.swift); configuration via [`WebSocketOutboundFlowConfiguration`](../API/WebSocketOutboundFlowConfiguration.swift) on [`ServerConfig`](../API/ServerConfig.swift); inbound **`ack`** routing in [`WebSocketTopicSubscriptionRouter`](WebSocketTopicSubscriptionRouter.swift).

### Client → server: cumulative `ack`

- **`{ "kind": "ack", "topic": "<same topic string>", "upTo": <seq> }`** means the client has processed every harness envelope for that **`topic`** whose **numeric** **`seq`** satisfies **`seq ≤ upTo`**.
- **`upTo`** must be non‑decreasing per topic per connection; regressive **`ack`** frames are ignored.
- Only **`kind: event`** lines consume server-side **inflight credit** when flow limiting is on; all valid topic envelopes now carry a parsable top-level **`seq`**. **`snapshot`** and **`lagging`** are written **immediately** (handshake/replay/pressure signals) and **do not** occupy inflight slots.

### Default / first-`ack` gate

- Flow limiting is **on** by default (**`WebSocketOutboundFlowConfiguration.enabled`** defaults to **`true`** at the composition root). Set **`WebSocketOutboundFlowConfiguration.disabled`** to opt out; without credit windows a slow WebSocket client can drive unbounded server-side buffering.
- **`applyLimitsToHighFrequencyEventsBeforeFirstAck`** (default **`true`**) applies credit windows to high-frequency **`event`** topics (`conversation/{id}/events`, trace streams, sub-agent `*/events`) **immediately**, even before the first client **`ack`**.
- **`limitOnlyAfterFirstAckPerTopic`** (default **`true`**) still defers credit windows on **state-like** topics until that topic receives its **first** **`ack`**.

### Credit windows (after limiting applies)

Per subscribed **`topic`**, the server tracks **`event`** payloads it has written to the socket but not yet covered by **`ack.upTo`** (**inflight count**). Limits are **count‑based** (not bytes), split by class:

| Class | Topics | Policy |
|-------|--------|--------|
| **High‑frequency `events`** | `conversation/{id}/events`, `subagent/{conversationId}/{path}/events`, `trace/{conversationId}`, `trace/server` | **Never coalesce** queued **`event`** lines—each delta is semantically distinct. If inflight is at cap, additional **`event`** lines are **queued** server‑side until **`ack`** frees capacity or the disconnect thresholds fire. |
| **State‑like** | `conversation/{id}/state`, `model/{id}/state`, `pool/health`, `models/registry`, capability registry topics, `conversations/registry`, `subagent/{conversationId}/{path}/state` | When over capacity and **`coalesceStateTopicsWhenOverCapacity`** is **`true`**, the server keeps **at most one** pending unsent **`event`** line per topic and replaces it with the **latest** payload (**latest wins**). **`snapshot`** subscribe handshakes still bypass queuing (sent immediately). |

**`snapshot`** and **`lagging`** outbound frames bypass inflight credit checks (subscribe/replay/resync and pressure signals must not deadlock the handshake).

### Soft warning: `lagging` + `hint: "flow_pressure"`

When **inflight** **`event`** count (unacked lines written for that topic) crosses configured soft thresholds (see configuration defaults), the server may emit an extra harness **`lagging`** envelope with **`hint: "flow_pressure"`** (same JSON shape as replay **`lagging`**, **`seq`** is the latest seen for that topic). Emissions are **cooldown‑gated** to avoid spamming the client. Queue depth alone does **not** trigger this hint—the client already stalled when frames are buffered behind the hard window.

### Hard limits and disconnect

If queued **high‑frequency** **`event`** lines exceed **`disconnectPendingEventsThreshold`**, or approximate **queued UTF‑8 bytes** across pending queues exceed **`disconnectBufferedBytesThreshold`**, the server invokes the WebSocket **disconnect** hook for that connection (policy violation / overload). No **`event`** lines are dropped silently on hot paths—overload is handled by **disconnect** after bounded buffering.

### Control responses and flow limiting

`ack` credit accounting applies to harness topic `event` traffic. Harness control responses (`kind:error`, `kind:dedupe_result`) are immediate control-plane responses and are not credit-windowed topic events.

---

## 7. Embedded / in-process transport parity

The embedded path uses the same topic taxonomy and harness envelope family as `/ws`, but over in-process channels instead of sockets.

- Hubs expose in-process subscriber registration plus topic-scoped subscribe/unsubscribe APIs.
- In-process subscribe follows the same reconcile-and-watch shape as WS:
  - optional replay from `since` (and conversation-event replay variants where supported),
  - `lagging` when replay cannot be satisfied,
  - then `snapshot`, followed by live `event` fan-out for subscribed topics.
- Publish gating (`hasSubscribers`) now includes both WS and in-process subscribers, so the same publish facades drive both transports.
- Lockstep migration rule: no legacy in-process firehose fallback path is retained; this is the single canonical embedded contract.

### Embedded flow-control posture

WebSocket `ack`/credit flow-control remains a WebSocket transport concern. In-process channels are treated as effectively non-backpressured delivery paths unless and until an explicit bounded in-memory queue policy is introduced. This is an intentional transport-level difference, not a protocol-shape fork.

---

## Appendix: HTTP preconditions (REST)

Optimistic concurrency for **`If-Match`** / **412** / **428** on REST mutations is **not** defined in this WebSocket policy doc.

- **Intentional exceptions** (routes that omit strict **`If-Match`** today, with rationale): same document, subsection **HTTP preconditions — intentional exceptions**.
