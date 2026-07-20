# Communication Layer — Recommended Architecture

## TL;DR

Expose the inner ring as a **schema-defined wire protocol** with two planes: an **HTTP control plane** for CRUD, list, search, and capability queries, and a **WebSocket data plane** that multiplexes a fixed taxonomy of pub/sub topics over one connection per client. The data plane's dominant traffic is **streaming model output on `conversation/{id}/events`** — token deltas, reasoning blocks, and tool-call deltas, interleaved in one ordered stream per conversation — and every other property of the wire (envelope shape, backpressure rules, replay window sizing, multiplexing) is sized for that case. Every resource topic supports **reconcile-and-watch** (snapshot then tail change events) with per-subscription **sequence numbers and a replay window** so dropped clients reconnect cleanly. The schema is the source of truth and client SDKs are generated from it. The Communication Layer is a peer of the other inner-ring layers, not a sub-concern of the Conversation Manager — the other layers publish events into it; it routes them to subscribed clients without knowing what the events mean.

The recommended shape is a TypeBox-defined Gateway WebSocket protocol with generated Swift bindings, consumed by native client apps. The pattern is the most fully-realized approach; other harnesses ship pieces of it.

---

## Why this belongs as its own layer

A harness with one client (a CLI in the same process) doesn't need a Communication Layer — direct method calls on the inner ring work fine. The minute there's a second client (a web UI, a mobile app, a Slack channel adapter, a cron scheduler firing into the runtime, an IDE speaking ACP), three failures appear:

1. **Each surface re-implements the same plumbing.** Authentication, subscription management, reconnect, replay, backpressure — every surface needs them and every surface gets them slightly wrong. The CLI maintains state the web UI doesn't; the mobile app loses state the CLI keeps; the Slack adapter has its own ad-hoc retry.
2. **State streams scatter.** Token deltas live in one place, model status in another, conversation lifecycle events in a third. There's no single subscription that gives a client what it needs to render a coherent UI.
3. **The Conversation Manager grows tentacles.** Without a layer that owns the wire, it's natural to put the wire on whichever existing layer is closest — usually Conversation Manager, because conversations are the most-subscribed resource. That layer then accumulates RPC handling, subscription management, replay, auth, and topic routing — none of which are conversation concerns.

The Communication Layer exists so the inner ring can publish events into one substrate, surfaces can consume one wire format, and every subscription / RPC / streaming concern lives in one place that nothing else has to know about.

A second reason worth naming: **this layer is the public face of the harness.** The shape of the wire protocol is the shape of the API third-party clients integrate against. Getting it wrong is more expensive than getting any other layer wrong — internal layers can be refactored, but the wire is a contract.

---

## Recommendation

### Two planes, not one

Split the protocol into a **control plane** (request/response) and a **data plane** (multiplexed pub/sub).

**Control plane — HTTP (REST-shaped).**

Use plain HTTP for operations that are inherently request/response and don't stream. The endpoint set, with concurrency-control posture per the [Preconditions and concurrency](#http-control-plane-preconditions-and-concurrency) subsection below:

| Endpoint | Purpose | Precondition support |
|---|---|---|
| `POST /conversations` | create | none (id is server-assigned) |
| `GET /conversations` | list (with filters) | `If-None-Match` → 304 |
| `GET /conversations/{id}` | read state snapshot (one-shot, not subscription); supports `?includeDerived=true` to return both `rawEvents` and `derivedEvents` arrays | `If-None-Match` → 304 |
| `PATCH /conversations/{id}` | update metadata, mode, attached resources | **`If-Match` required** → 412 on mismatch; 428 in strict mode |
| `DELETE /conversations/{id}` | archive / delete | **`If-Match` required** → 412 on mismatch; 428 in strict mode |
| `POST /conversations/{id}/messages` | append input / new turn | **`If-Match` required** on last-message-id → 412 on mismatch; 428 in strict mode |
| `POST /conversations/{id}/checkpoints` | Engine append to `derivedEvents` (internal) | **`If-Match` required** on last-checkpoint-id of the same kind |
| `POST /conversations/{id}/branch` | branch from a point | `If-Match` on parent's last-message-id (recommended) |
| `POST /conversations/{id}/cancel` | cancel an in-flight turn | `If-Match` on `currentRunId` (recommended; idempotent without it) |
| `GET /conversations/{id}/runs` | list runs (derived from `rawEvents`) | `If-None-Match` → 304 |
| `GET /conversations/{id}/runs/{runId}` | fetch a single run record (derived from `rawEvents`; use for reconnect / polling after WebSocket drop — prefer the data plane for live progress) | `If-None-Match` → 304; ETag is stable once run reaches a terminal outcome |
| `GET /conversations/{id}/events?since=N` | history backfill | `If-None-Match` → 304 |
| `POST /conversations/{id}/projection` | on-demand projected view — the message array the model would see now, or under an alternative `AssemblyConfig` in the body. Used by transparency UIs and Engine debugging | none (stateless query) |
| `GET /models` | list available models with capabilities | `If-None-Match` → 304 |
| `POST /models/query` | capability-based selection | none (stateless query) |
| `GET /tools` | global tool registry — all registered tools, unfiltered by conversation or mode. For admin UIs, plugin developers, and anything that needs to know what is installed regardless of context. | `If-None-Match` → 304 |
| `GET /conversations/{id}/tools` | tools available to a specific conversation: global registry filtered by conversation `toolWhitelist` ∩ active mode `allow`/`deny`. Per-run whitelists are not reflected here — they are only known at `appendInput` time and may narrow this set further at runtime. | `If-None-Match` → 304 |
| `GET /skills` | global skill registry — all installed skills, unfiltered by conversation or mode. | `If-None-Match` → 304 |
| `GET /conversations/{id}/skills` | skills available to a specific conversation: global registry filtered by conversation routing policy ∩ active mode skill allow/deny. | `If-None-Match` → 304 |
| `GET /sub-agents` | registry reads | `If-None-Match` → 304 (per registry) |
| `GET /search?q=...` | cross-conversation search | none (query-dependent, changes every append) |
| `GET /traces/{conversationId}` | fetch a trace span set | none (debug path) |

The reason to keep these on HTTP rather than push them onto the WebSocket: HTTP is what every tool in the world already knows how to test, document, cache, rate-limit, and authenticate. OpenAPI tooling lights up for free. Browser clients can hit it from `fetch()` without holding the WebSocket open. There's no good reason to recreate request/response semantics inside a streaming protocol when REST handles it natively.

**Data plane — WebSocket, multiplexed by topic.**

One connection per client, regardless of how many conversations / models / registries the client subscribes to. Subscriptions are messages on the connection, not separate connections.

```ts
// Client → server
{ kind: "subscribe", topic: "conversation/c_abc/events", since?: number }
{ kind: "unsubscribe", topic: "conversation/c_abc/events" }
{ kind: "ack", topic: "conversation/c_abc/events", upTo: number }

// Server → client
{ kind: "snapshot", topic: "model/m_sonnet45/state", seq: 1024, value: {...} }
{ kind: "event", topic: "conversation/c_abc/events", seq: 1025, value: {...} }
{ kind: "error", topic?: string, code: string, message: string }
{ kind: "lagging", topic: string, hint: "resync" }
```

The envelope is intentionally narrow: every server→client message carries `{topic, seq, value}` plus the kind, and `seq` is monotonic *per topic per subscription*. That's the minimum the reconnect-and-replay logic needs. Keep it small; resist the urge to add request-correlation IDs, server timestamps, or client-IDs to the envelope itself — those belong in `value` if at all.

### HTTP control plane: preconditions and concurrency

The semantic optimistic-concurrency anchors in the Manager and Persistence specs (`expectedVersion` on `update`, `expectedLastMessageId` on `appendMessage`, `expectedLastCheckpointId` / `basedOnEventId` on `appendCheckpoint`) ride on the wire as **standard HTTP preconditions per RFC 9110**. Each anchor maps to an `If-Match` header; the response taxonomy uses the canonical RFC status codes; OpenAPI surfaces both the parameter and the typed error responses so SDK codegen produces conflict-aware clients automatically. This is the wire-level mechanism for everything the architecture commits to under "multi-client attach + concurrent edits."

The OSS-harness corpus is early on this — none of the six surveyed harnesses use HTTP preconditions on their own API surface. The architecture's commitments (multi-client conversation attach, schema-defined wire, OpenAPI as source of truth) all point at preconditions; the corpus just hasn't matured into needing them yet.

**The contract:**

| Header | Method class | On match | On mismatch | On absent (strict mode) |
|---|---|---|---|---|
| `If-Match: "<etag>"` | unsafe (`PATCH` / `DELETE` / write `POST`) | request proceeds | **`412 Precondition Failed`**, no state change | **`428 Precondition Required`** |
| `If-None-Match: "<etag>"` | safe (`GET`, `HEAD`) — cache validation | **`304 Not Modified`**, no body | request proceeds, fresh body + new ETag | (not applicable) |

**On a `412`, include the current ETag in both the response header and the JSON body.** The redundancy is deliberate — generic HTTP tooling reads the header; SDK codegen reads the body for typed conflict errors:

```json
{
  "error": "precondition_failed",
  "currentVersion": "msg-a3f2c901",
  "yourVersion": "msg-a3f2c8a4",
  "resourceUrl": "/conversations/c_abc/messages"
}
```

The server makes no state modification on a 412; the client can safely fetch fresh state and retry without further coordination.

**ETag scheme — strong validators tied to the underlying anchor.** No weak (`W/"..."`) prefix; concurrent-edit safety needs byte-exact match, not coarse equivalence:

| Resource | ETag value | Bumped on |
|---|---|---|
| Conversation header | `"conv-v<state-version>"` | every `PATCH` / lifecycle transition |
| Message log | `"msg-<lastMessageId>"` | every append to `rawEvents` |
| Checkpoint log (per kind) | `"ckpt-<kind>-<lastCheckpointId>"` | every append to `derivedEvents` of that kind |
| Run (single and list) | `"run-<sha-of-serialized-representation>"` | any change to any representation input: log append, `state.runStatus` / `state.currentRunId` transition, orphan reconciliation |
| Registry (tools, skills, sub-agents, models) | `"reg-<sha-of-serialized-contents>"` | every register / unregister / capability update |

Runs are *derived* resources whose representation depends on more than the log — see [conversation-manager/runs.md § Cache validators for derived run resources](../conversation-manager/runs.md#cache-validators-for-derived-run-resources) for the invariant and the two validator schemes that get this wrong (identity tags, log-position proxies). The identity form `"run-<runId>"` survives in exactly one place: as the synthetic `If-Match` precondition token on cancel. It is never a cache validator, and the two token families are not interchangeable.

The prefix (`conv-`, `msg-`, `ckpt-`, `reg-`) is informational — lets you tell at a glance which kind of resource a stray validator belongs to — but the comparison is on the full string. Pick a prefix scheme and don't change it.

**Strict mode (return `428` if `If-Match` absent).** Per-deployment configuration, off by default. Enable on:

- `PATCH /conversations/{id}` — protects against blind metadata overwrites in multi-client setups
- `DELETE /conversations/{id}` — protects against deleting a conversation that's transitioned since you saw it
- `POST /conversations/{id}/messages` — protects against blind appends that would corrupt the log tail

Single-client local CLIs don't need any of this. Multi-client gateways and any deployment with concurrent editors should turn strict mode on at least for the third (the message-log tail is the most damaging place to lose a write race).

**Cheap version reads are load-bearing.** `If-None-Match` only saves bandwidth if checking the current ETag is fast — typically a column read on the catalog row or an in-memory registry hash, not a re-serialization of the resource. The version field needs to live in catalog metadata that's cheap to query (per [persistence](../../backends/persistence/) — the catalog already carries `state-version`, `lastMessageId`, etc.). If the server has to recompute the resource to know whether to return 304, the bandwidth saving is offset by CPU; spec the version source explicitly per resource. The exception is derived resources with no single cheap anchor — run records are the canonical case, since no catalog column captures every representation input. There, correctness outranks cheapness: hash the representation, and if poll volume warrants, recover the fast path with a server-side validator cache keyed on the complete input tuple (per [conversation-manager/runs.md](../conversation-manager/runs.md#cache-validators-for-derived-run-resources)).

**OpenAPI surfaces it end-to-end.** The schema (per [§ Schema-defined and code-generated](#schema-defined-and-code-generated) below) treats `If-Match` as a typed parameter on every guarded endpoint; the `412` and `428` responses are typed errors in generated SDKs; `If-None-Match` and `304` are typed on the read side. Clients that ignore preconditions get caught by the type system at compile time, not by silent overwrites at runtime.

### Topic taxonomy

Three scopes. Subscribe per resource; subscribe once for server-wide; opt in to traces.

**Resource-scoped (subscribe per id).**

| Topic | Carries |
|---|---|
| `conversation/{id}/events` | combined feed: persisted Message envelopes (from `rawEvents`), persisted Checkpoint envelopes (from `derivedEvents`), and transient runtime progress; see "Conversation events: persisted arrays vs transient progress" below |
| `conversation/{id}/state` | active model id, mode (chat/agent), attached resources, system-prompt overrides, context-budget remaining, current loop phase |
| `model/{id}/state` | derived state (idle / thinking / generating / queued), in-flight count, rate-limit window, latency window |
| `subagent/{conversationId}/{path}/events` | nested-agent activity addressable by parent conversation + path within fan-out tree |

**Server-scoped (one subscription, get everything).**

| Topic | Carries |
|---|---|
| `models/registry` | snapshot of available models + capabilities; events on add/remove/cap-change |
| `tools/registry` | snapshot of registered tools + schemas; events on registration changes |
| `skills/registry` | snapshot of discoverable skills; events on load/unload |
| `sub-agents/registry` | snapshot of available agent delegates (in-process and remote) |
| `pool/health` | aggregate Model Pool / Sub-Agent Pool health, queue depths, error rates |

**Trace-scoped (opt in, high volume, observability-shaped).**

| Topic | Carries |
|---|---|
| `trace/{conversationId}` | span events for model calls, tool calls, sub-agent invocations, turn boundaries; structured attributes; high frequency |
| `trace/server` | server-wide infrastructure spans (pool scheduling, registry loads) |

Trace topics should be cheap to disable (they're observability, not application data) and never on the critical path. Treat them as OpenTelemetry-shaped under the hood; the wire format here is just the transport.

### Conversation events: persisted arrays vs transient progress

The `conversation/{id}/events` topic is doing triple duty, and the distinction matters for clients deciding what to render and what to ignore. The Conversation Manager stores conversation history as **two persisted arrays** (`rawEvents: [Message]` and `derivedEvents: [Checkpoint]` — see [conversation-manager.md](../conversation-manager/)), and on top of that the Runtime emits **transient progress** during in-flight turns. All three classes flow over this one topic:

**Persisted Message envelopes** (appends to `rawEvents`). These survive across restarts, appear in `read(id)`, and are what reconcile-and-watch resumes against on reconnect for the raw stream. Concrete kinds: `InputMessage`, `AssistantMessage`, `ToolCallMessage`, `ToolResultMessage`. The user-visible history of what happened. History-rendering clients filter to these.

**Persisted Checkpoint envelopes** (appends to `derivedEvents`). These also survive restart and appear in `read(id, { includeDerived: true })`. Concrete kinds: `CompactionCheckpoint`, `MemoryInjectionSnapshot`, `ToolResultTrim`, `SystemPromptAssembly`, `AttachmentDigest`. The Context Engine's work. Visible to clients that want to render "compaction is running," "what summary did the model see," or transparency UIs. Hidden by default in conversational chat UIs.

**Transient progress envelopes (run-scoped, not persisted).** Emitted by the Agent Runtime *during* an in-flight turn and not persisted to either array. They include the streaming `model.contentDelta` events covered in the next section, plus per-iteration loop phase markers, tool-call lifecycle events while a tool is executing, and sub-agent spawn/result lifecycle events. They tag with the owning `runId` so clients can correlate; they end with the run's terminal event. The completed assistant message lands as a single committed `AssistantMessage` envelope at the end of the run; the deltas have already streamed.

**State changes are not a fourth class on this topic.** When the conversation's mode flips from `chat` to `agent`, the active model id changes, or attached resources update, those transitions ride on `conversation/{id}/state` only — which emits a change envelope to each subscriber after their initial snapshot (see "State vs events" below). The events topic carries history and run progress; state lives on the state topic. Consumers that need both subscribe to both.

Why three classes on one topic: clients consume them together. A live UI shows token deltas streaming in, sees a `CompactionCheckpoint` envelope land if the Engine fires mid-turn, and sees the committed `AssistantMessage` envelope arrive when the run ends. A history UI ignores transient deltas and renders Message envelopes. Splitting any of these into separate topics fragments the order; clients have to merge them anyway. One topic, three envelope classes discriminated in the envelope kind (`message` | `checkpoint` | `progress`), filtered by subscribers.

The replay semantics differ:

- **Persisted Message and Checkpoint envelopes replay from per-array seq buffers.** Each persisted array has its own monotonic sequence; a client reconnecting can pass `sinceMessageSeq` and `sinceCheckpointSeq` and get the missed ranges. Buffer windows can be sized differently per array — Messages are higher-volume and benefit from larger windows; Checkpoints are sublinear and can keep more history.
- **Transient envelopes do not replay.** A client that disconnects mid-turn and reconnects sees the committed envelopes for that turn (if finished) but doesn't get earlier token deltas back. If the run is still in flight when the client reconnects, the wire resumes streaming from wherever the model is now — earlier deltas of the in-flight assistant message are not buffered for new subscribers. Document this clearly to clients; the alternative (buffering all transient progress for late subscribers) is too expensive.

### Streaming model output on `conversation/{id}/events`

The single highest-volume, lowest-latency-tolerant data path in the system, and the one every other concern in this document is sized to support. Get this right and the wire works for everything else; get it wrong and no amount of correct framing elsewhere will save you.

**What flows on this topic, in arrival order during a turn:**

| Event | Notes |
|---|---|
| `input.received` | User message or trigger envelope arrived; trust class set |
| `turn.started` | Turn id, selected model id, projected cost ceiling |
| `loop.iterationStarted` | Iteration counter, current message count |
| `model.callStarted` | Pool dispatched; first byte awaited |
| `model.contentBlockStarted` | New block opening — `kind: "text" \| "reasoning" \| "toolCall"`, block index |
| **`model.contentDelta`** | **The dominant traffic.** Incremental content — see shape below |
| `model.contentBlockCompleted` | Block index N is final |
| `model.callCompleted` | Stop reason, usage info, total cost, latency stats |
| `tool.callStarted` | Tool name, arguments, permission state |
| `tool.progress` | Optional intermediate output for long-running tools |
| `tool.callCompleted` | Result or error, tool-result trust class |
| `subagent.spawned` | Path within fan-out tree; routes events to `subagent/{conv}/{path}/events` |
| `subagent.completed` | Final summary folded back to parent stream |
| `loop.iterationCompleted` | Iteration N done |
| `turn.completed` | Final stop reason, total iterations, total cost |

**The content-delta shape (the one that matters):**

```ts
type ContentDelta =
  | { index: number; kind: "text"; textDelta: string }
  | { index: number; kind: "reasoning"; reasoningDelta: string; redacted?: boolean }
  | { index: number; kind: "toolCall"; toolName?: string; argsDelta: string }
```

`index` is the block index within the assistant message; multiple blocks can stream concurrently in providers that support it (parallel tool calls especially). `toolName` arrives on the first delta of a `toolCall` block; `argsDelta` streams the JSON arguments incrementally. UIs can render "preparing to call read_file…" as soon as the tool name is known, before arguments finish.

**Five rules that fall out of this being the dominant traffic:**

1. **Token deltas can't be coalesced.** State events (per-model state) can be collapsed to "latest wins" under backpressure. Token deltas can't — each delta is unique payload. Backpressure on this topic means buffer + lag-warn + (worst case) lag the subscription out. You don't drop tokens to keep up.
2. **Order is load-bearing.** Tokens out of order produce garbled output. The seq-per-topic guarantee covers this, but it means you can't shard one conversation's stream across connections; one conversation's events are one ordered stream by design.
3. **One topic carries all kinds.** Don't split into `conversation/{id}/tokens`, `conversation/{id}/tools`, `conversation/{id}/lifecycle`. The kinds share the same total order — interleaving content with tool execution within one ordered stream is the only way clients can correctly reconstruct what happened. Splitting fragments the order and forces clients to merge with imperfect information.
4. **Provider event shapes are normalized at the Pool boundary, not on the wire.** Anthropic's `content_block_delta`, OpenAI's `choices[0].delta`, Bedrock's framed events all become the uniform `model.contentDelta` shape *before* the runtime sees them, let alone before they hit the wire (see [model-pool.md](../model-pool/) on adapter normalization). Clients never see provider-specific shapes.
5. **Reasoning and tool-call deltas are the same shape as text deltas.** Three `kind`s, one envelope. Reasoning gets its own `kind` because UIs typically render it collapsibly (or honor `redacted: true` and hide it entirely). Tool-call deltas are still deltas — emit the function name first, stream the JSON arguments after, let the client render progressively. Don't buffer until the call is complete; the partial deltas are useful.

**Sub-agent streams are parallel topics, not multiplexed onto the parent.** When a turn fans out to a sub-agent, that sub-agent's content streams onto `subagent/{parent-conv}/{path}/events` (same shape, same envelope, separate seq counter). The parent's `conversation/{conv}/events` carries a `subagent.spawned { path }` lifecycle event when the fan-out begins and a `subagent.completed { path, summary }` when it lands. Clients that want a full tree view subscribe to all sub-agent topics for the conversation; clients that want only top-level activity subscribe to the parent. Don't try to merge sub-agent token streams into the parent's stream — the order semantics fall apart.

**Practical throughput.** A model generating at 50 tok/s emits ~50 deltas/s on one conversation. Five concurrent streaming conversations is 250 events/s — modest. Twenty concurrent sub-agents fanning out under one user is 1000 events/s — meaningful. The envelope has to be small enough that per-message overhead doesn't dominate. JSON works at the lower end; for the high end, consider binary framing (CBOR or MessagePack) on the same envelope schema. The schema is the source of truth either way; the encoding is per-deployment.

**Cost on the wire vs cost rendered.** A token delta is small (often a few characters of payload + envelope overhead). The total bandwidth is dominated by the content itself, not the framing. Compression (permessage-deflate on WebSocket) helps for text but adds CPU; for high-fanout deployments, profile before deciding. Don't pre-optimize.

### State vs events: reconcile-and-watch on every resource topic

Distinguish the two:

- **State** is the current value of something ("this model is generating, 14k tokens consumed, 186k remaining").
- **Events** are transitions ("started generating," "emitted token delta," "finished").

Clients want both, and they want them composed: when I subscribe, give me the current snapshot first, then tail subsequent changes. That's the **reconcile-and-watch** pattern (Kubernetes informers, Firebase Realtime DB, Convex queries). Without it, every client either replays history from the beginning or accepts a missing-state window.

For `*/state` topics, send a `snapshot` message immediately on subscribe with the full current value, then send `event` messages for each subsequent change. For `*/events` topics, you can ship the same shape but the snapshot is empty (events are point-in-time and have no "current value"); clients can request a backfill via the control plane (`GET /conversations/{id}/events?since=...`) if they need history.

The contract that makes this work in practice: a freshly-connected client should be able to render a complete UI for any subscribed resource in one round-trip — the snapshot — and then stay current via the event stream. If your topic shape doesn't satisfy that, it's not designed correctly.

**One projection of state, on the state topic only.** A `*/state` topic already publishes a transition envelope every time its underlying value changes — that's what the post-snapshot `event` messages are. Don't also cross-post those transitions onto an `*/events` topic. Mode flipping from `chat` to `agent`, the active model id changing, attached resources updating — these all ride on `conversation/{id}/state` and only there. The `*/events` topics are reserved for kinds that aren't state-derived (persisted history envelopes, transient run progress); admitting a state-change envelope class onto them creates two write paths for the same fact and lets the two topics' views drift. Subscribers that want state transitions interleaved with run progress subscribe to both topics — one extra `subscribe` message on the connection they already hold. The topic separation keeps each topic's purpose legible and the single-source-of-truth property between snapshot and stream intact. The general rule: **state is authoritative, the state topic carries the only event projection of state, and `*/events` topics never carry state-change envelopes.**

### Sequence numbers and replay window

Every subscription gets a per-topic monotonic `seq` in each delivered message. The server keeps a bounded buffer of recent messages per topic. On reconnect, the client passes `since: <last-seen-seq>` in the `subscribe` message:

- If the requested seq is still in buffer, replay the missed range.
- If it's older than the buffer's tail, send a fresh `snapshot` and a `lagging` notice; client knows it lost some intermediate events but has a consistent state to resume from.

Buffer sizes are per-topic. High-frequency topics (token deltas) can have small replay windows (a few seconds); low-frequency topics (registry changes) can keep hours. This is the bit that makes mobile clients usable on flaky networks; without it every backgrounded tab is a re-sync from scratch.

A useful refinement: include a server-side **resume token** rather than a raw seq number, so the server is free to renumber internally without breaking clients. Same shape from the client's side; more freedom on the server's side.

### Schema-defined and code-generated

The wire format is a contract; treat it like one. Pick a schema language (TypeBox / Zod / protobuf) and make the schema the *artifact*. Generate:

- Server-side request/response and event types
- Client-side TypeScript types
- Native client bindings (Swift for iOS, Kotlin for Android, Rust if relevant)
- OpenAPI / AsyncAPI documents for the control plane
- Validation at the wire boundary (parse-don't-validate)

The TypeBox→Swift pipeline pattern is the proof point: the iOS app, the macOS app, and the web client all consume types generated from one TypeBox source. When the protocol changes, the build breaks at every consumer that has not been updated — which is exactly what you want.

The cost of doing this on day one is small: a build step. The cost of retrofitting it after three clients have diverged is a multi-week migration with subtle wire-format bugs.

### Subscription authorization and trust class

Two checks per subscription request:

1. **Authorization.** Is this client allowed to subscribe to this topic? `conversation/{id}/*` should require ownership or explicit share; `pool/health` might be admin-only; registries are usually open to any authenticated client.
2. **Trust class on outbound.** Some topics carry content that originated from `unknown-party` sources (web-fetch results that the agent quoted, attachments from a public webhook). The Comm Layer doesn't have to enforce content-level trust handling — that's the Context Engine's job upstream — but it should *tag* outbound messages with the trust class of their content so client UIs can render security indicators (e.g., "this part of the response was based on untrusted web content"). This keeps trust visible all the way to the user surface, not just inside the runtime.

Authorization happens at the connection layer (one auth check per connection) plus at subscription time (one check per topic). Don't auth per-message; that's overhead that gets you nothing.

### Backpressure and flow control

WebSocket is happy to buffer indefinitely on either side, which is exactly what you don't want. Two mechanisms:

- **Per-subscription credit.** Client sends `ack { topic, upTo: seq }` periodically; server stops sending past the un-acked window plus N. For high-frequency topics this matters; for low-frequency it can be no-op.
- **Coalescing for state topics.** If multiple `state` events queue up for one topic during a backpressure stall, collapse them to the latest (state is idempotent — only the current value matters). For `events` topics, you can't coalesce because events are individually meaningful — drop into `lagging` instead.

The server's behavior under sustained client backpressure should be principled, not best-effort. Document it: "lagging" notification at threshold, drop and re-snapshot at hard limit, disconnect at extreme.

### How the inner ring publishes

In-process publish API for the other six layers:

```ts
type CommLayer = {
  publishSnapshot<T>(topic: string, value: T): void
  publishEvent<T>(topic: string, value: T): void
  registerRpc(method: string, handler: (req: any) => Promise<any>): void
}
```

Each inner-ring layer publishes its own events. The Model Pool publishes `model/{id}/state` and `models/registry`. The Conversation Manager publishes `conversation/{id}/state` and `conversation/{id}/events`. The Agent Runtime publishes loop-phase transitions onto the conversation's events topic. The Tool System publishes `tools/registry` and contributes tool-call events to the conversation. Crucially: layers don't subscribe to each other through the Comm Layer — that would route in-process events through serialization unnecessarily. The Comm Layer is *the way out*; in-process coordination uses direct calls or a separate in-process event bus.

A useful design rule: a layer's `publish*` calls should be the *only* way that layer surfaces information to clients. If a layer also exposes a method that returns state, the Comm Layer should call that method to compose the initial snapshot — that way the snapshot and the change events are two views of the same source of truth, and they can't drift.

### Embedded mode

For the CLI-only deployment, the Comm Layer should run in-process with an in-memory transport: same publish/subscribe API, same envelope shape, same topics, no socket. The CLI client and the server are two ends of an in-process channel. The user never sees the difference; you never maintain two runtimes. This is the embedded-mode-as-in-process trick from the [README](../README.md) — and the Comm Layer is the single component that determines whether it works. If the Comm Layer's API is hostile to in-process use (e.g., it requires sockets to be configured, or it mandates JSON serialization on every message), you've foreclosed the embedded path.

---

## Alternatives

### SSE-only

Server-Sent Events as the only data-plane transport. One HTTP connection per topic; a separate HTTP API for sending input.

**When this works:** when the client is a single-page web app talking to a single conversation, you don't have remote sub-agents, and you don't care about mobile / flaky networks. SSE is one-way, well-supported by browsers, and easy to test with `curl`. The OpenAI Chat Completions streaming API is SSE-shaped for exactly this case.

**Why not as default:** every additional resource the client wants to subscribe to is another HTTP connection. A client that wants to render a dashboard with three conversations + the model pool state + the tools registry needs five concurrent SSE connections, plus the input HTTP API. This becomes resource-prohibitive on mobile and breaks under HTTP/1.1's per-host connection limits in browsers. WebSocket multiplexed by topic gets the same job done with one connection.

### gRPC streaming

A typed, codegen-friendly streaming RPC framework.

**When this works:** when all your clients are native (no browsers), you already use gRPC elsewhere in the stack, and you'd rather have generated typed RPC stubs than design a custom envelope.

**Why not as default:** browser support is awkward (gRPC-Web is a separate, less-capable thing). Casual debugging with `wscat` or browser devtools doesn't work. The streaming model is per-call rather than per-topic, which fights the multi-subscription shape we want. And gRPC's connection semantics interact poorly with the reconcile-and-watch pattern — you end up reinventing it inside the streaming RPC.

If you go this way, the protocol shape ends up being: a single bidirectional streaming RPC where messages on the stream are the same `{topic, seq, value}` envelope. At which point you've recreated WebSocket-with-typed-codegen and accepted the browser-support cost. Defensible if the trade-off is worth it for your clients; not the default.

### NATS / MQTT / Redis Streams as the internal bus, WebSocket at the edge

The inner ring publishes into a real pub/sub broker; the Comm Layer is a thin gateway translating broker subscriptions to WebSocket subscriptions.

**When this works:** when the harness is multi-process or multi-node — you have multiple Gateway instances behind a load balancer, or the Model Pool is a separate process, or sub-agents are running in a fleet. The broker becomes the substrate; the Comm Layer is one consumer of it.

**Why not as default:** for a single-process Gateway it's overkill — you've added an external dependency to solve a problem you don't have. The good news: the topic-shaped Comm Layer API makes this migration cheap. If you decide later to split, the wire format stays the same; only the publish/subscribe implementation changes. Don't pre-build, but design so you don't preclude.

### HTTP polling

Every N seconds, the client polls `GET /conversations/{id}/state` and re-renders.

**When this works:** never, for an agent harness. Agent activity is bursty (no events for minutes, then a tool call every 200ms during execution), so any poll interval is wrong: long enough to feel laggy during activity, short enough to waste resources during idle. Don't.

The only place polling has any place: as a fallback for dead-simple clients that can't hold a WebSocket open (e.g., a shell script). Even then, model that as a control-plane convenience, not as the primary data plane.

---

## Anti-patterns

- **Conflating control and data on one shape.** Tempting because "everything goes over the WebSocket is simple." It isn't: control-plane RPCs benefit from HTTP semantics (caching, rate-limiting, OpenAPI docs, browser `fetch()` compatibility); data-plane events benefit from streaming semantics (multiplexing, replay, backpressure). Keeping them on one transport saves you nothing and costs you both sets of benefits.
- **Per-connection state on the server.** If a client's subscriptions, sequence numbers, or replay windows are tied to its TCP connection, every reconnect is a re-sync from scratch and graceful client failover is impossible. State belongs to the *subscription identity* (a token the client presents on reconnect), not the connection.
- **Per-message authentication.** Auth at connection setup; trust the connection thereafter. Auth on every message is overhead that buys you nothing — if the connection is compromised, you've lost regardless of message-level checks.
- **Treating ACP as the internal protocol.** ACP is *a* client protocol — fine for IDE bridges and stdio agent integrations — but it's not rich enough to be your internal one. It lacks the multi-subscription shape, the reconcile-and-watch pattern, and the resource-graph semantics you need for a multi-surface client. The right approach: ACP is bridged *into* the Gateway protocol, not used as the Gateway protocol.
- **HTTP REST for the agent stream.** Familiar, easy to test, immediately wrong. Token deltas, multi-turn tool calls, and sub-agent fan-out are not request/response shaped. Several harnesses start here and migrate; save yourself the migration.
- **Splitting one conversation's stream across multiple topics.** "Tokens go on `conversation/{id}/tokens`, tool-call lifecycle on `conversation/{id}/tools`, agent-loop events on `conversation/{id}/lifecycle`." Looks tidy; destroys the total order of events, which is the one property clients actually need to reconstruct what happened. One ordered stream per conversation, one topic, multiple `kind`s.
- **Cross-posting state changes to the events topic.** "When mode flips, also emit a `modeChanged` envelope on `conversation/{id}/events` so subscribers don't have to listen to two topics." Looks like a small ergonomic win; creates two write paths for the same fact. The state topic and the events topic can drift, late subscribers see different histories on each, and the events topic loses its clear semantics (history + run progress). State transitions ride on the state topic only; subscribe to both topics if you need both — subscription is cheap.
- **Buffering full tool calls before emitting.** Waiting until the model has finished emitting the tool name and all arguments before sending anything to subscribers. Trades a tiny implementation simplification for a noticeable UX regression — clients can render "preparing to call X..." as soon as the tool name is known, often a second or two before arguments finish. Stream the deltas.
- **Coalescing token deltas under load.** "If we're behind, drop intermediate deltas and only send the latest." Coalescing is correct for *state* topics (only the latest matters); deltas are not state — each one carries unique content and dropping them produces garbled output. If the wire can't keep up, lag the subscription and warn; never drop tokens.
- **Provider event shapes leaking onto the wire.** The client receives `content_block_delta` for one model and `choices[0].delta` for another. Now every client has provider-specific code paths, and adding a third provider is a wire-protocol change. The Pool's adapters normalize *before* the runtime; the wire only carries the normalized shape.
- **No replay buffer.** Without one, every disconnected client is missing data on reconnect and has to re-fetch state out-of-band. With a small buffer (seconds for high-frequency topics, hours for low-frequency), the same reconnect resumes seamlessly. The cost is small bounded memory; the benefit is mobile clients that actually work.
- **Schema as an afterthought.** Designing the wire informally and writing the types by hand on each side. Within three clients the types diverge, validation is inconsistent, and a wire change becomes a coordination nightmare. Make the schema a generated artifact from day one.
- **Letting the Conversation Manager own the wire.** The original mistake. If the Conversation Manager has methods named `subscribe`, `broadcast`, `disconnect`, or types named `Client` / `Connection`, the layering is wrong. Conversations don't know about clients; the Comm Layer does.
- **Using `409 Conflict` for `If-Match` mismatch.** RFC 9110 §13.1.1 ties the `If-Match` header specifically to `412 Precondition Failed`; using `409` instead means generic HTTP tooling, browser caches, and SDK codegen don't recognize the concurrency case. Reserve `409` for resource-state conflicts that aren't precondition-driven (request well-formed but logically incompatible with current state — e.g., trying to start a run on a conversation that's `archived`). Pick `412` when the *header* failed the check; pick `409` when the *request body's logic* is incompatible with state. They mean different things to clients.
- **Weak validators where strong are needed.** A weak ETag (`W/"v42"`) signals "this is a coarse equivalence — same revision, byte-different content allowed." Concurrent-edit safety requires byte-exact match; use strong validators throughout. Weak validators are only correct for the cache-conditional `GET` case where you don't care about byte equality (and even there, strong is fine — there's rarely a reason to prefer weak in this architecture).
- **Conditional `GET` without a server-side version cache.** If the server has to recompute the resource and re-serialize it to derive an ETag on every `If-None-Match` check, the `304` saves bandwidth but burns the CPU you were trying to save. The version (state-version, last-message-id, registry sha) needs to be cheaply readable — typically a column on the catalog row, an in-memory atomic counter, or a hash maintained on write. If you can't answer "what's the current ETag of resource X" in microseconds without touching the resource itself, `If-None-Match` isn't ready to ship for that resource.
- **Per-resource `version` body field instead of `If-Match`.** A request body that carries `{ version: "v42", patch: {...} }` works, but it's reinventing what HTTP already specifies, and it forfeits all the leverage: OpenAPI doesn't know it's a concurrency control, browser caches don't help, generated SDKs don't expose typed `Precondition Failed` errors, and proxies can't reason about it. Use the header. Body fields for concurrency control are a smell — every place a real-world API uses them is a place that wasn't sure HTTP preconditions existed.

---
