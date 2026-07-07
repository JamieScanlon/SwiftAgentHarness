# Runs — Recommended Architecture

## TL;DR

A **run** is one execution of the agent loop within a conversation: input arrives → assistant streams → tools dispatch → loop terminates. The Conversation Manager exposes run-oriented operations (`appendInput`, `cancelRun`, `getRun`, `listRuns`) but **runs are not a separately-stored entity** — they are a *derived view* over the `rawEvents` log that the [Conversation Manager](./README.md) already owns. This page nails down: the segmentation rule that derives runs from `rawEvents`, the cross-layer cancellation contract, and the explicit decision to leave deliberate user-driven pause/resume out of scope.

The big architectural choice this page defends: **persisting runs as their own table is unnecessary.** `rawEvents` is the source of truth; what counts as "a run" is a function over that log. Anything that wants run-shaped data — UI listings, budget rollups, audit trails — derives it. The single counterexample is **scheduled-task / cron run history**, which has different semantics (delivery tracking) and lives in [persistence](../../backends/persistence/) under `cron/runs/<jobId>.jsonl`. Agent runs do not need that machinery.

---

## Why runs are derived, not stored

Three reasons the architecture commits to deriving:

1. **`rawEvents` is already the source of truth.** Per the README, raw messages are immutable, append-only, and never deleted. Run boundaries are entirely visible in that log: an `InputMessage` of trust class `user`/`owner`/`channel-*`/`trigger` opens a run; a terminal `AssistantMessage` (or a cancellation marker entry) closes it. Storing a separate `runs` row introduces a second source of truth that can drift.
2. **Run state is mostly transient.** The fields a run needs while in flight (`runStatus`, `currentRunId`, in-progress accumulator) live in memory and on the conversation header (`state.runStatus`, `state.currentRunId`). Once the run terminates, almost nothing about it is novel — the messages it produced, the tools it called, the cost it incurred are all already in `rawEvents` and in the catalog's per-message rollups.
3. **The OSS corpus mostly does this already.** Single-binary CLI implementations derive run history by reading the JSONL transcript; a `SessionManager` pattern exposes turn-shaped views over the same tree; tracking active runs in memory and persisting outcomes via the message log is also sound. Harnesses that persist runs separately via framework checkpoints or session lineage chains end up with two-source-of-truth bugs. Don't repeat that.

---

## Recommendation

### Runs as a derived view

The segmentation rule applied to `rawEvents` to produce run boundaries:

**Run starts:** an `InputMessage` whose `trustClass ∈ {user, owner, channel-trusted, channel-untrusted, trigger}` — i.e., not an internal continuation (tool result feeding the next iteration is part of the *same* run, not a new one).

**Run ends:** the first of these, walking forward from the start:
- A terminal `AssistantMessage` — `finish_reason ∈ {stop, end_turn, max_tokens}` and no tool calls, or all tool calls have completed and the next assistant turn has terminal stop reason
- A `custom` entry with `customType: "run_cancelled"` — runtime persisted this on cancellation (see [Cancellation contract](#cancellation-contract))
- A `custom` entry with `customType: "run_errored"` — runtime persisted this on unrecoverable error
- A `custom` entry with `customType: "run_bounded"` — `maxIterations` cap, context-budget exhausted, or tool-system halt signal (see [agent-runtime § Stop conditions](../agent-runtime/#stop-conditions))

**Open run (the current head):** the tail of `rawEvents` past the last terminal entry, when `state.runStatus === "running"` or `"awaiting-approval"`.

### Run record shape (derived)

`getRun` and `listRuns` return:

```ts
type Run = {
  id: string                     // assigned at appendInput time, persisted in the opening InputMessage's metadata
  conversationId: string
  startedAt: number              // timestamp of the opening InputMessage
  endedAt: number | null         // timestamp of the terminal entry, or null if open
  outcome: "completed" | "cancelled" | "errored" | "bounded" | "open"
  iterationCount: number         // count of assistant turns in the segment
  toolCallCount: number
  tokens: TokenRollup            // sum across model calls in this segment
  cost: CostRollup
  firstMessageId: string         // boundary anchor — the opening InputMessage.id
  lastMessageId: string | null   // boundary anchor — the terminal entry.id; null if open
  cancellationReason?: string    // populated when outcome === "cancelled"
  errorDetails?: { class: string; message: string }   // when outcome === "errored"
}
```

The fields are computed by walking the segment between `firstMessageId` and `lastMessageId`. For frequently-listed conversations, the catalog can cache a `runs_index` materialized from message metadata; the canonical answer is always the derivation.

### Run id assignment

A run id is assigned when `appendInput` opens a new run, persisted on the opening `InputMessage` (e.g., `metadata.runId`). All entries appended during that run carry the same `runId` in their metadata. This makes derivation a simple group-by over `rawEvents` rather than a sequence-number walk that has to interpret each entry's role.

The runtime never makes up a run id; the Manager assigns it. Sub-agent runs in nested conversations get their own run ids in the nested conversation's `rawEvents` — they don't share the parent's run id.

### Cancellation contract

Cancellation crosses three layers — Conversation Manager → Agent Runtime → (transitively) Tool System and Sub-Agent Pool. The contract that ties them together:

**1. Caller invokes `Manager.cancelRun(conversationId, runId)`.**
- Manager verifies the runId matches `state.currentRunId`. If not, returns `RunNotInFlight`.
- Manager flips `state.runStatus` from `running` (or `awaiting-approval`) to `cancelling` *(transient state, not in the public enum — internal to the Manager between cancel signal and runtime confirmation)*.
- Manager fires the `AbortSignal` previously handed to the runtime.

**2. Runtime responds per [agent-runtime § Cancellation hygiene](../agent-runtime/#cancellation-hygiene):**
- Stop reading from the Pool's event stream; the Pool tears down the upstream model call.
- Discard partial assistant message accumulation — never append a half-streamed message.
- Cancel any in-flight tool calls (signal pass-through; force-kill after grace period if the tool doesn't honor it).
- For any in-flight sub-agent invocations, propagate cancel through the Sub-Agent Pool (see [sub-agent-pool § Cancellation propagation](../sub-agent-pool/#cancellation-propagation)).

**3. Runtime appends a cancellation marker to `rawEvents`** under the conversation's write lock:

```json
{
  "type": "custom",
  "customType": "run_cancelled",
  "id": "...",
  "parentId": "<last entry id>",
  "metadata": {
    "runId": "<runId>",
    "iteration": <int>,
    "reason": "<user-cancel | parent-cancel | deadline | budget>",
    "cancelledAt": <ts>
  }
}
```

This marker is what makes the run derivable as `outcome: "cancelled"`. Without it, derivation can't tell a cancelled run apart from an open one whose runtime crashed.

**4. Runtime emits `turn.cancelled` on the Comm Layer event topic, then returns.**

**5. Manager observes the runtime return**, transitions `state.runStatus` from `cancelling` to `cancelled` (the public enum value), clears `state.currentRunId`, and publishes the state change.

**Edge cases:**

- **Cancel during `awaiting-approval`.** The runtime is parked waiting on a permission decision. `cancelRun` resolves the pending decision as `denied-cancelled` (so any waiting tool dispatch returns a `cancelled` error), the runtime resumes briefly only to append the `run_cancelled` marker and return.
- **Cancel after model call completed but before tool dispatch.** The assistant message is fully formed; append it normally, then append the `run_cancelled` marker. Don't drop the assistant message — it's a real thing the model said, and `rawEvents` is the unedited record.
- **Cancel mid-tool-result trim.** The `ToolResultTrim` checkpoint write is not part of `rawEvents`; it's an Engine-owned `derivedEvents` entry. Cancel it normally; it can be rewritten on resume.
- **Double cancel.** Idempotent. Second `cancelRun` returns the existing cancelled state without re-firing the signal.
- **Cancel of a run that has already terminated.** Returns `RunAlreadyEnded(outcome)` — no-op, not an error.
- **Cancel propagation from parent.** If the parent conversation cancels and this conversation is a sub-agent run, the Sub-Agent Pool delivers the cancel here as a parent-initiated `cancelRun` with `reason: "parent-cancel"`.

The cancellation marker entry in `rawEvents` is what makes everything else derivable. Skipping it is the most common implementation bug; the run becomes indistinguishable from an open run whose process died.

### Resumption after restart

The Manager doesn't directly resume runs across process restarts — that's an [agent-runtime](../agent-runtime/#resumption-stateless-replay-from-rawevents) concern (the runtime is stateless and reentrant). What the Manager *does* do on startup:

1. Load each conversation's header from the catalog.
2. For any conversation with `state.runStatus ∈ {running, awaiting-approval, cancelling}` and no live runtime: this run was orphaned by the previous process death.
3. Append a `custom` entry of type `run_orphaned` to `rawEvents` with metadata `{runId, lastSeenAt, recoveredAt}`. This closes the run for derivation purposes.
4. Set `state.runStatus = "idle"`, clear `state.currentRunId`.
5. The conversation is now reachable in its prior state (history intact) but no run is in flight; the user (or trigger) decides whether to re-input.

This is the **conversation-level** orphan recovery contract. Sub-agent runs that were in flight when the process died have their own recovery flow — see [sub-agent-pool § Orphan recovery](../sub-agent-pool/#orphan-recovery-after-gateway-restart).

### Why deliberate pause/resume is out of scope

The OSS-harness corpus surveyed ships **zero** features for deliberate user-driven run-pause. What they ship instead, in order of universality:

| Feature | Universal? | Notes |
|---|---|---|
| Cancel / interrupt (Ctrl-C, abort signal cascade) | All six | Table stakes |
| Conversation-resume across processes | All six in some form | Reload state and continue from last terminal message |
| Permission-gate pause/resume (sub-agent waiting for approval) | Most production harnesses | Required for any approval-gated tool |
| Orphan / crash recovery for long-running children | Gateway-based harnesses | Synthetic resume message after gateway restart |
| Spawn-pause circuit breaker (block new spawns) | one harness alone | Operational tool |
| Deliberate user-driven run-pause | None | — |

The use cases people imagine for run-pause collapse into other features:

- "Save my work and come back later" → conversation persistence + suspend/resume (covered by `state.lifecycle = "suspended"` and reattach)
- "Stop this runaway thing" → `cancelRun` (covered)
- "Wait, let me approve this tool call" → permission gate (covered by `awaiting-approval`)
- "I want to inspect mid-run" → streaming visibility plus cancel-and-restart-from-`rawEvents` (covered)
- "Pause budget consumption while I think" → no real use case once the runtime is stateless and re-prompting is cheap

The implementation cost of deliberate pause is high relative to payoff: mid-stream pause means cancelling the in-flight model call (often impossible mid-generation), capturing partial assistant text and pending tool dispatches, releasing the transcript write lock, persisting enough state to reconstruct the run. Compare to the recommended path — `cancelRun` + later `appendInput` — which works because the runtime is largely deterministic over the same prefix and prompt-cache makes the second model call cheap.

If a real use case for deliberate pause materializes, the natural shape is: a `paused` value in `runStatus`; pause boundaries strictly between iterations (never mid-generation); a `run_paused` custom entry in `rawEvents` that resume reads and continues from. But none of that is built; treat it as future work and don't ship the API surface speculatively.

### Listing and pagination

`listRuns(conversationId, opts?)` walks `rawEvents` for the conversation, segments by the rule above, and returns runs newest-first by default. Options:

- `kinds?: ("live" | "trigger" | "channel" | "delegate")[]` — filter by the trust class of the opening InputMessage. Default: all kinds.
- `outcomes?: ("completed" | "cancelled" | "errored" | "bounded" | "open")[]` — filter by terminal disposition.
- `since?: number` — runs that started after timestamp.
- `limit?: number` — default 50, paged via `cursor`.

For very long conversations, walking the full `rawEvents` log per `listRuns` call is wasteful. The catalog can maintain an optional materialized `runs_index(conversation_id, run_id, started_at, ended_at, outcome, first_message_id, last_message_id, ...)` populated by triggers on `messages` insert. This is a cache; the canonical answer is always derivation. If the cache and the derivation disagree, the derivation wins and the cache is rebuilt.

---

## External HTTP API

The four Manager operations map to the following HTTP control-plane endpoints. Authoritative precondition semantics live in the [Communication Layer § Preconditions](../communication-layer/#http-control-plane-preconditions-and-concurrency). Live run progress (turn started / cancelled / completed) is streamed over the WebSocket data plane on `conversation/{id}/events` — these endpoints are for control and state retrieval, not for replacing the stream.

### `POST /conversations/{id}/messages` — appendInput

Appends input to a conversation and, if no run is in progress, starts one. This is the primary entry point for all agent execution — direct user input, trigger-originated messages, and channel arrivals all flow through here.

**Request body:**

```ts
{
  content: InputContent          // text, image, or multi-part block
  trustClass?: TrustClass        // defaults to "user" for direct API callers; overridden by trigger / channel surfaces
  runOptions?: {
    model?: ModelQuery           // per-run model override; falls back to conversation routing
    maxIterations?: number       // per-run iteration cap; falls back to global config
    toolWhitelist?: string[]     // per-run tool restriction; intersected with conversation whitelist
  }
}
```

**Response — 201 Created:**

```ts
{ runId: string; messageId: string }
```

`runId` is the id assigned to the run opened by this input — use it to call `cancelRun` or correlate data-plane events. `messageId` is the id of the `InputMessage` appended to `rawEvents` — use it to anchor a branch or a replay.

**Preconditions:** `If-Match: "msg-<lastMessageId>"` required in strict mode. Absent in strict mode → 428. Present and mismatched → 412 with current ETag in body.

**Error responses:**
- `409` — conversation is `archived`, `suspended`, or `deleted` (state incompatible with starting a run; not a precondition failure)
- `409` — a run is already in progress and the multi-client attach policy rejects queuing a concurrent input
- `412` — `If-Match` mismatch
- `428` — `If-Match` absent in strict mode

---

### `POST /conversations/{id}/cancel` — cancelRun

Signals cancellation to the in-flight run. Initiates the three-layer cascade defined in [§ Cancellation contract](#cancellation-contract): Manager fires the AbortSignal → Runtime tears down the model call and in-flight tools → Sub-Agent Pool propagates cancel to any delegate runs.

**Request body:**

```ts
{ runId: string }
```

**Response — 200 OK:**

```ts
{ runId: string; outcome: "cancelled" }
```

**Idempotency:** double-cancel is a no-op; the second call returns 200 with the same already-cancelled outcome. Cancel of a run that reached a terminal outcome returns 409 `RunAlreadyEnded` (not an error from the caller's perspective — the desired outcome exists).

**Preconditions:** `If-Match: "run-<runId>"` is recommended but not required (the body `runId` provides sufficient scoping). Including it makes the call atomic with respect to a specific run — useful when racing against natural run completion.

**Error responses:**
- `409 RunNotInFlight` — `runId` does not match `state.currentRunId`; no run is in flight with that id
- `409 RunAlreadyEnded` — run reached a terminal outcome before the cancel signal arrived; body includes `{ outcome: "completed" | "errored" | "bounded" }`

---

### `GET /conversations/{id}/runs/{runId}` — getRun

Returns the derived `Run` record for a single run. The record shape is defined in [§ Run record shape (derived)](#run-record-shape-derived).

**Response — 200 OK:** a `Run` object.

**Cache semantics:** `If-None-Match` / `304` supported. The ETag is `"run-<runId>"` while the run is open (its fields can change as iterations accumulate). Once the run reaches a terminal outcome the record is immutable and the ETag remains stable indefinitely — clients polling for completion can issue conditional `GET`s cheaply without re-parsing unchanged bodies.

**Prefer the data plane for live progress.** `turn.started`, token deltas, `tool.callStarted`, and `turn.completed` all arrive on `conversation/{id}/events` with lower latency than polling this endpoint. Use `getRun` for reconnect scenarios — a client that drops its WebSocket mid-run and needs to recover the current run state without replaying all events — and for fetching completed run metadata after the fact.

**Error responses:**
- `404` — `runId` not found in `rawEvents` for this conversation

---

### `GET /conversations/{id}/runs` — listRuns

Returns a paged list of derived `Run` records for the conversation, newest-first by default.

**Query parameters** (all optional):

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `kinds` | `("live" \| "trigger" \| "channel" \| "delegate")[]` | all | Filter by trust class of the opening `InputMessage` |
| `outcomes` | `("completed" \| "cancelled" \| "errored" \| "bounded" \| "open")[]` | all | Filter by terminal disposition |
| `since` | `number` | — | Unix timestamp (ms); return runs that started after this point |
| `limit` | `number` | 50 | Page size; capped at 200 |
| `cursor` | `string` | — | Opaque continuation cursor from a prior response |

**Response — 200 OK:**

```ts
{
  runs: Run[]
  cursor?: string    // present when more results exist; pass as `cursor` on the next request
  total?: number     // advisory count; may not be exact for large conversations; omit if expensive
}
```

**Cache semantics:** `If-None-Match` / `304` supported. ETag is tied to the message-log ETag (`"msg-<lastMessageId>"`); any new run opening or closing invalidates it.

**Performance:** if the catalog's optional `runs_index` materialization (see [§ Listing and pagination](#listing-and-pagination)) is present and current, it serves this endpoint directly. If absent or stale, derivation over `rawEvents` is the fallback. The response is identical either way; callers need not know which path was taken.

---

### Priority and phasing

`appendInput` (`POST /conversations/{id}/messages`) and `cancelRun` (`POST /conversations/{id}/cancel`) are on the critical path for every agent interaction — ship them as first-class control-plane endpoints in the initial API surface.

`getRun` (`GET /conversations/{id}/runs/{runId}`) should ship alongside them. Clients that drop their WebSocket connection mid-run need a recovery path that doesn't require replaying the full event log; this endpoint is that path.

`listRuns` (`GET /conversations/{id}/runs`) can follow once a consuming UI surface or audit requirement is driving the pagination and filter semantics. The derivation logic is shared with `getRun` and adds no new infrastructure; the deferral is about API surface management, not implementation cost.

---

## Alternatives

### Persist runs as a separate table

A `runs` table in the catalog with a row per run — opened on `appendInput`, finalized on terminal entry.

**When this works:** when run-shaped queries dominate access patterns (regulatory audit logs, billing systems exporting per-run cost, training-data harvesting that batches by run). The catalog row gives O(1) access for those use cases.

**Why not as default:** introduces a second source of truth. If the catalog row updates fail after the message append succeeds (or vice versa), the run state in the table diverges from the message log. The reconciliation logic isn't free, and every consumer has to decide which source they trust. Derivation has none of that — there's one log and one rule.

If you do need a `runs_index`, treat it strictly as a derivation cache (rebuildable from `rawEvents`), not as the source of truth. That is the lesson from session lineage chains that used derivation caches as sources of truth.

### Persist runs as JSONL adjacent to the transcript

Mirror the cron pattern: `runs/<conversationId>.jsonl`, one append per run with start/end/outcome/cost.

**When this works:** if your transcript schema doesn't carry message metadata (no `runId` field, no entry types beyond `message`) and you can't add it. Then runs need their own log.

**Why not as default:** the architecture commits to per-message `metadata` and entry-type discrimination already (per [persistence § "Open-set entry types"](../../backends/persistence/#the-transcript-log-per-conversation)). Adding a parallel JSONL just to record run boundaries duplicates information that's already in `rawEvents`. Use the `custom` entry types (`run_cancelled`, `run_errored`, `run_bounded`, `run_orphaned`) instead.

### Treat each run as a separate conversation

Every `appendInput` creates a new conversation; the "session" is the chain of conversations linked by `parentId`.

**When this works:** for sharply transactional workloads where conversations are genuinely one-shot — a slash-command bot, a webhook responder. Each invocation is a new conversation; `listRuns(parentConversationId)` becomes "list children."

**Why not as default:** breaks the architecture's core commitment that the conversation is the unit of identity for the agent and that history is shared across runs. The conversation is *meant* to outlive runs; a chat conversation has dozens of runs and they share context. Don't shred that to make run derivation easier.

---

## Anti-patterns

- **Persisting runs to a separate table without treating it as a cache.** Two sources of truth that drift; pick one and make the other derivation. (Same anti-pattern as engine-artifact cache being treated as authoritative.)
- **Forgetting to append the cancellation marker.** Cancelled runs become indistinguishable from open runs whose process died. Derivation can't tell what happened. The marker is small, cheap, and load-bearing.
- **Inferring run boundaries from sequence-number gaps.** "If the timestamp jumps by 30 seconds, that's a new run." Brittle; breaks under cancellation, breaks under sub-agent latency, breaks under network jitter. Use explicit metadata (`runId`) on every entry.
- **Spec'ing `pauseRun` / `resumeRun` speculatively.** No OSS harness ships it; the use cases collapse into existing features. Adding the API surface invites callers to depend on it before the semantics are nailed down. Wait for a real use case.
- **Cancellation that doesn't propagate.** Manager fires the signal, runtime stops, but in-flight sub-agents and tool calls keep running. Tool results land after the run is "cancelled," confusing derivation and burning budget. The contract is end-to-end; cancellation cascades down the tree.
- **Using `errored` for cancellation.** Cancellation is not an error — the user did exactly what they wanted. The `runStatus` enum has both for a reason; conflating them loses the user's intent.
- **Dropping a partially-streamed assistant message on cancel mid-stream.** Half-streamed messages should not be appended to `rawEvents` (per [agent-runtime § Cancellation hygiene](../agent-runtime/#cancellation-hygiene)). But: an assistant message that *fully streamed* before the cancel signal should be kept — the model said it, the rawEvents log records what happened, and discarding it makes the next replay non-deterministic.
- **`getRun` / `listRuns` reading from in-memory runtime state.** The runtime is stateless across invocations; in-memory state doesn't survive restart. Always derive from `rawEvents`. The runtime's in-memory accumulator is for the current iteration, not for run history.
- **Letting a `runs_index` cache become authoritative.** Treat it as rebuildable from `rawEvents` at all times. If the cache diverges (schema migration, partial write failure), trust the log and rebuild.

---
