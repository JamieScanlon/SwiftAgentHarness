# Conversation Manager — Recommended Architecture

## TL;DR

The Conversation Manager owns the **conversation as a first-class addressable resource**: CRUD, branching, mode (chat / agent), attached resources, system-prompt overrides, lifecycle. Conversations are the unit of identity for the agent — its messages, its tools, its budget, its in-flight runs, its sub-agents — and they're addressed by id, not by client connection. **Multiple clients can attach to one conversation; client disconnect doesn't kill the conversation.** Sub-agent runs are nested conversations owned here. Persistence is a backend driver, not part of this layer.

The Manager is the entry point for the harness's external API: every operation a client wants to perform — list my conversations, create a new one, attach to an existing one, send input, switch mode, branch from a point — is a method call on this layer. The Communication Layer translates wire RPCs into Manager calls; the Manager doesn't know clients exist.

The recommended session model covers stable id with reattach, event taxonomy, per-conversation model selection, the conversation event shape, trust class on input, and key namespacing for trigger-originated sessions.

---

## Why this belongs as its own layer

Without a dedicated layer, "the conversation" gets scattered: the runtime holds the message history, the persistence backend holds the file, the UI holds the active conversation id, the model client holds the system prompt, the tools layer holds the per-conversation tool whitelist. Each of these is a copy of "what's true about this conversation right now," and they drift. The Manager exists so there's exactly one source of truth for the conversation's state, addressable by one stable id, and reachable from every other layer through one interface.

Three other reasons it belongs as its own layer rather than rolled into runtime or persistence:

1. **The runtime is per-turn; the conversation is across-turns.** Conflating them ties conversation lifecycle to runtime invocation lifecycle, which makes "show me my conversations" or "this conversation has been idle 30 minutes, suspend it" awkward. Separate the resource from the work performed on it.
2. **The persistence backend is implementation; the conversation is interface.** What clients want is the operation set ("create," "branch," "list," "attach"); how those operations get durable is a backend concern. Keeping them separate lets you swap SQLite for Postgres for object storage without touching the client surface.
3. **The conversation is the convergence point for triggers, channel arrivals, and direct user input.** Per the [triggers](../../surfaces/triggers/triggers.md) work and the [Communication Layer](../communication-layer/), all input enters through the Manager: "append this input to conversation X, with trust class Y." If the Manager isn't a layer, triggers have nowhere to land except the runtime, which conflates input arrival with turn execution.

---

## Recommendation

### The conversation as a resource

```ts
type Conversation = {
  id: string                                    // stable, addressable
  parentId?: string                             // if branched or sub-agent
  ownerAccountId: string

  metadata: {
    title: string                               // user-set or auto-derived
    tags: string[]
    createdAt: number
    lastActiveAt: number
  }

  state: {
    lifecycle: "active" | "suspended" | "archived" | "deleted"
    mode: "chat" | "agent"                      // see "mode" below
    runStatus: "idle" | "running" | "awaiting-approval" | "cancelled" | "errored"
    currentRunId?: string                       // if running
  }

  prompt: {
    systemOverride?: string                     // per-conversation override
    extraInstructions?: string                  // appended to defaults
  }

  routing: {
    modelQuery?: ModelQuery                     // per-conversation model preference
    modelOptions?: {
      thinkingConfig?: ThinkingConfig           // runtime thinking toggle; overrides mode default. Patched by the user at any idle point — does not require a mode change. See model-pool/README.md for ThinkingConfig type and full resolution order.
    }
    toolWhitelist?: string[]                    // restrict tools available this conversation
    skillsOverride?: string[]                   // restrict skills loaded this conversation
  }

  attachments: AttachedResource[]               // files, URLs, datasets

  budget: {
    max?: number                                // total spend ceiling
    spent: number
    contextBudgetRemaining?: number             // tokens left in active model's window
  }

  rawEvents: Message[]                          // append-only history; source of truth (see "The event log and the projected view" below)
  derivedEvents: Checkpoint[]                   // Engine-produced, supersedable, prunable
  branches?: { childId: string; branchedAtMessageId: string }[]
}

// Raw events — strictly append-only, never invalidated, never deleted
interface Message {
  id: string                                    // stable identifier; survives reordering, replay, branching
  ts: number
  // Concrete subtypes implement specific payloads:
}
interface InputMessage extends Message { trustClass: TrustLevel; content: InputContent }
interface AssistantMessage extends Message { content: AssistantContent }
interface ToolCallMessage extends Message { toolName: string; arguments: unknown }
interface ToolResultMessage extends Message { forToolCallId: string; result: ToolResult }

// Derived events — produced by the Context Engine, validated at projection time, prunable when superseded
interface Checkpoint {
  id: string
  ts: number
  configFingerprint: string                     // hash of the policy that produced this
  basedOnEventId: string                        // raw-event id when the work started — for optimistic concurrency
  // Concrete subtypes carry their own coverage shape:
}
interface CompactionCheckpoint extends Checkpoint {
  coveredMessageIds: string[]                   // raw messages whose contribution this synthesis replaces
  syntheticMessages: Message[]                  // the projection-side replacement
}
interface MemoryInjectionSnapshot extends Checkpoint { hits: MemoryReference[]; memoryStoreVersion: string }
interface ToolResultTrim extends Checkpoint { targetMessageId: string; trimmedView: ToolResultMessage }
interface SystemPromptAssembly extends Checkpoint { atTurn: number; assembledPrompt: string }
interface AttachmentDigest extends Checkpoint { attachmentId: string; contentHash: string; digest: ContentBlock[] }
```

A few notes on the shape:

- **`id` is stable and addressable.** Clients use it to reattach. URLs in the web client use it. Mobile push notifications reference it. Don't make it tied to a connection or session-token; it's a resource id.
- **`parentId` is set for branched conversations and sub-agent conversations alike.** The conversation tree is the same shape for both; the distinguishing fact is "was this branched from a user gesture or spawned by a delegate."
- **`state.lifecycle`** is separate from `state.runStatus`. A conversation can be `active` and `idle` (no turn running, but reachable); `active` and `running` (turn in progress); `suspended` (no turn allowed; reattach to resume); `archived` (read-only, hidden from default lists); `deleted` (soft-deleted; gone from UI but recoverable for some window).
- **Per-conversation overrides** for prompts, model, tools, and skills are first-class. This is what makes "let me try this conversation with a cheaper model" or "this conversation is for code review only — limit tools to read/search" tractable without touching defaults.
- **`branches`** is metadata, not the branched conversations themselves; child conversations are full Conversation records with `parentId` set. The `branches` field is a denormalized index for quick "what did this conversation branch into." The branch point is identified by message id, not array index — message ids are stable identifiers across reordering, replay, and storage migrations.
- **`rawEvents` and `derivedEvents` are deliberately two arrays, not one tagged union.** They have different mutation rules (raw is strictly append-only and never deleted; derived is Engine-owned, supersedable, and prunable), different access patterns (history rendering walks raw; the projection function walks both but treats them differently), different cardinality and growth (raw grows linearly; derived sublinearly), and different storage shapes (two tables / two log files in the backend). Modeling them as one array forces every consumer to filter on a discriminator and forces dynamic-typing patterns (`payload: Any`) in static languages. Keeping them separate is structural — the type system carries the distinction. The temporal correlation between them is preserved by `Checkpoint.basedOnEventId` pointing at a raw `Message.id` — that's a stronger anchor than interleaved insertion order.

### The event log and the projected view

The single most important seam in the Conversation Manager, and the one that gets collapsed most often: **what the model sees on each turn is not the same artifact as what the conversation contains.**

- **The raw-event log** (`rawEvents: Message[]`) is append-only, single-writer-ordered, and owned by the Manager. Every input, assistant message, tool call, tool result that has ever been committed lives here, exactly as written. Raw messages are immutable. This is what `branch(...)` forks against, what `search(...)` indexes, and what a transparency UI walks.
- **The derived-event log** (`derivedEvents: Checkpoint[]`) is the Context Engine's append-only stream of work products: compaction checkpoints, memory snapshots, tool-result trims, optional system-prompt assemblies. Checkpoints are stored as written but can be silently invalidated by their built-in validity check (so a stale checkpoint is harmless — just ignored at projection time), and superseded ones can be pruned later.
- **The projected view** is the message array the Context Engine produces at the start of each turn by walking both arrays, finding the latest valid checkpoint of each kind, and applying transformations: compaction synthesis, memory injection, tool-result trimming, attachment inlining, system-prompt assembly. It is *not stored as a separate field;* it's a pure function of `(rawEvents, derivedEvents, config)`. Only the model sees it; once the turn is done it can be discarded (or recorded as a `SystemPromptAssembly` checkpoint for transparency).

Compaction is a transformation that produces the projected view, *not* a rewrite of raw events. It does so by appending a `CompactionCheckpoint` to `derivedEvents` whose payload describes how to substitute the projection. The same pattern applies to every other context-shaping operation: each appends a Checkpoint subtype to the derived array. No transform ever mutates a raw message; all of them affect what the model sees this turn through the projection function.

```
   ┌──────────────────────────────────────┐  ┌──────────────────────────────────────┐
   │  rawEvents: [Message]                │  │  derivedEvents: [Checkpoint]         │
   │  (append-only; source of truth)      │  │  (Engine-owned; validatable)         │
   │  ──────────────────────────────────   │  │  ──────────────────────────────────   │
   │  m1   InputMessage  "hello"          │  │  c1  CompactionCheckpoint            │
   │  m2   AssistantMessage  "..."        │  │        coveredMessageIds: [m1..m12]  │
   │  m3   ToolCallMessage  read_file     │  │        syntheticMessages: [...]      │
   │  m4   ToolResultMessage  (blob)      │  │        configFingerprint: "abc123"   │
   │  ...                                  │  │        basedOnEventId: "m12"         │
   │  m12  AssistantMessage  "..."        │  │  c2  ToolResultTrim                  │
   │  m13  InputMessage  "next thing"     │  │        targetMessageId: "m4"         │
   │       ← turn starts                  │  │        basedOnEventId: "m12"         │
   └─────────────────┬────────────────────┘  └─────────────────┬────────────────────┘
                     │                                         │
                     └────────────────────┬────────────────────┘
                                          │ ContextEngine.project(rawEvents, derivedEvents, config)
                                          ▼
                ┌──────────────────────────────────────────────────────┐
                │  Projected view (sent to model)                      │
                │  ───────────────────────────────────────────────────  │
                │  system prompt (composed for this turn)              │
                │  [synthetic msgs from c1]  ← prefix substitution     │
                │  m4 with c2 trimmed view substituted                  │
                │  ... (raw messages m5..m12 if not covered by c1)      │
                │  m13 (current input)                                 │
                └──────────────────────────────────────────────────────┘
```

The projection's validity check makes the substitution safe:

```ts
function isCompactionCheckpointValid(
  ckpt: CompactionCheckpoint,
  rawEvents: Message[],             // in order
  currentConfig: AssemblyConfig,
): boolean {
  // 1. Coverage size cannot exceed the raw prefix
  if (ckpt.coveredMessageIds.length > rawEvents.length) return false
  // 2. The first N raw messages still match — guards against edits to early history
  const prefix = rawEvents.slice(0, ckpt.coveredMessageIds.length).map(m => m.id)
  if (!arraysEqual(prefix, ckpt.coveredMessageIds)) return false
  // 3. Config fingerprint matches — guards against policy changes
  if (ckpt.configFingerprint !== currentConfig.fingerprint()) return false
  return true
}

function latestValidCheckpoint<T extends Checkpoint>(
  derivedEvents: Checkpoint[],
  kind: new (...args: any[]) => T,
  rawEvents: Message[],
  currentConfig: AssemblyConfig,
): T | null {
  // Walk derivedEvents newest-first; pick the latest checkpoint of the given kind that's still valid.
  // If none are valid (edited history, config change, no checkpoints yet),
  // return null — the projection falls through to raw replay.
}
```

Each Checkpoint subtype has its own validity rule (compaction uses prefix-match; `ToolResultTrim` checks the target message still exists; `MemoryInjectionSnapshot` adds `memoryStoreVersion` match; `AttachmentDigest` checks content-hash match against the attachment's current bytes and has *no* prefix term — it depends on the artifact, not conversation position), but they share the shape: prefix/anchor check (where applicable) + config fingerprint.

This factoring buys you five things lossy compaction (mutating raw history) can't:

1. **Reproducibility.** "What did the model see on turn 23?" — replay `project(...)` against the events known at turn 23. With mutated history, you can't.
2. **Transparency.** Users and auditors can always inspect what really happened, distinct from what the model was shown — filter the event stream to raw events.
3. **Branching stays clean.** Branches inherit raw events plus any checkpoint whose coverage is entirely within the inherited prefix; the validity check rejects anything that doesn't fit. See "Branching" below.
4. **Policy changes are safe.** Switch models or compaction policies and the config-fingerprint check invalidates stale checkpoints automatically. The Engine recomputes against the still-intact raw history.
5. **Failure recovery.** A bad checkpoint (summarizer hallucinated) gets dropped or replaced — emit an invalidation event or simply emit a new checkpoint that supersedes it. With raw events intact, regeneration is just running the Engine again.

The cost is storage: the event log keeps growing. Bound it with archival, pruning of superseded derived events, and search indexes — never by mutating raw history. See "Pruning" below and [../../backends/persistence/](../../backends/persistence/).

#### What this means for the API surface

- **`read(id)` returns the user-visible conversation** — by default, `rawEvents` rendered as a message list. Clients displaying history see what actually happened. A `read(id, { includeDerived: true })` variant returns both arrays for clients that need them (debugging, transparency UIs, the Context Engine itself).
- **`project(id, config?)`** is the on-demand projection: the message array the model would see right now (or with an alternative config). Used for transparency UIs and Engine debugging. Not stored unless explicitly recorded as a `SystemPromptAssembly` checkpoint.
- **`latestValidCheckpoint(id, kind)`** returns the latest valid Checkpoint of the given subtype. Used by the Engine to decide whether incremental work is possible.
- **Subscribers to `conversation/{id}/events` see both Message and Checkpoint events** as distinct envelope kinds in the wire stream. A history-rendering client filters to Message kinds; a debug UI rendering "compaction is running" subscribes to Checkpoint kinds; the runtime needs both. The wire combines them; the Manager's storage and append paths keep them split.
- **`conversation/{id}/state` carries `contextBudgetRemaining` derived from the projection**, not from the raw count. The model only ever sees the projection, so its budget is what matters.
- **Branching inherits the parent's `rawEvents` through the branch point and any Checkpoint whose coverage is within the inherited prefix** by default. See the "Branching" subsection below.

### Concurrency and the compaction lock

Each array has its own writers. The runtime appends `Message`s (input, assistant, tool calls/results) — one in-flight run per conversation provides natural serialization. The Context Engine appends `Checkpoint`s (compaction, memory snapshot, tool-result trim) — and *here* races happen, because compactions can be triggered concurrently by the runtime, by a background memory-consolidation pass, or by an explicit client request. Without coordination, two compactions racing produce wasted work and ambiguous ordering.

The recommendation is **per-array single-writer ordering, with a compaction lock at the conversation scope on the derivedEvents side**:

- **Per-conversation compaction lock.** Only one compaction can be in flight per conversation. Other compaction attempts that arrive while the lock is held default to a no-op return of the existing latest valid checkpoint. The lock is held only for the duration of the LLM call that produces the synthesis.
- **Coverage-range idempotency.** A compaction attempt that would produce a checkpoint covering the same range as an existing valid checkpoint with the same config fingerprint is short-circuited — return the existing one, don't run.
- **Foreground turns never block on compaction commit.** If a turn arrives while compaction is in flight, the turn projects against the arrays as they exist *now* — using the previous valid checkpoint, ignoring the in-flight one. The new checkpoint commits when ready; the next turn picks it up. Compaction is a background concern from the foreground's perspective.
- **Optimistic write at the derived-events boundary.** Each Checkpoint records `basedOnEventId` (the raw-event id that was the latest when the compaction started). At commit time, the storage layer accepts the Checkpoint only if no conflicting Checkpoint of the same kind has landed since that anchor. If conflict, abort the write — the work is wasted but the array stays consistent. This is belt-and-suspenders given the lock; cheap to implement and catches bugs.

Raw `Message` writes (input arrivals, assistant turns, tool results) follow standard optimistic concurrency on their own array — `expectedLastMessageId` on the write, conflict-on-mismatch, retry from the new tail. There's no cross-array ordering concern because the temporal anchor between them is `Checkpoint.basedOnEventId`, not interleaved insertion order.

### Branching

A branch is created at a specific raw-message id (the branch point). The recommendation is **the branch inherits raw messages through the branch point, plus any Checkpoint whose coverage is entirely within the inherited prefix.** The validity check handles the rest naturally.

Concretely:

- **Inherit raw messages.** Copy `rawEvents[0..N]` from the parent to the branch (or implement as a shared-prefix reference if your storage supports it; semantically identical). Message ids stay stable.
- **Inherit selectively for derived events.** A Checkpoint is inherited iff its coverage lies entirely within the inherited message prefix. A `CompactionCheckpoint` covering messages 1-30 is inherited if N ≥ 30. A checkpoint covering 1-50 is *not* inherited if N = 40. A `ToolResultTrim` targeting message m20 is inherited if N ≥ 20. Position-independent checkpoints (`AttachmentDigest` — keyed on attachment content, no message coverage) are always inherited.
- **Don't inherit pending state.** In-flight compactions in the parent at branch time aren't carried over. The branch starts with a clean compaction-lock state.
- **`basedOnEventId` is rewritten if necessary.** If branch message ids are reassigned during inheritance, rewrite `basedOnEventId` accordingly. If you reference-share the prefix and ids stay stable, no rewrite needed.
- **Config fingerprint propagates.** The branch's compaction config defaults to the parent's. If the user changes config in the branch, fingerprint mismatch invalidates inherited checkpoints automatically.

Two edge cases:

- **Race between branch and compaction.** User branches while a compaction is in flight in the parent. If the branch operation linearizes before the compaction commits, the branch sees no in-flight state — clean. If the branch linearizes after, the new checkpoint is potentially included; the validity check (coverage exceeds branch point → reject) handles correctness either way. The race window is real but the validity check makes both outcomes safe.
- **Sub-agent forks use the same machinery.** A sub-agent spawned with `context: "fork"` is a branch under this rule (raw messages inherited up to spawn point, valid checkpoints inherited). A sub-agent spawned with `context: "isolated"` starts with empty arrays — same as a brand-new conversation.

### Pruning

`rawEvents` grows linearly with conversation length and is **never pruned** — it's the source of truth. `derivedEvents` grows sublinearly (one entry per compaction trigger, plus one per memory-injection snapshot, plus per tool-result trim) and **is** prunable when entries are superseded.

The recommendation is **lazy: prune at archive time and at branch time; reach for periodic background consolidation only when storage measurably hurts**:

- **At archive time, consolidate.** When a conversation moves to `archived` lifecycle state, find the latest valid Checkpoint of each kind, verify all earlier ones are strictly subsumed by its coverage, drop the synthetic-message payloads of superseded checkpoints (keep tombstone entries in `derivedEvents` if you want replay; otherwise hard-remove). Bounded one-time work at a natural lifecycle transition.
- **At branch time, filter.** Branch creation already filters out non-applicable Checkpoints per the inheritance rule above. No separate pruning step.
- **Optionally: periodic background consolidation.** For very long-running active conversations (months, thousands of turns), an autovacuum-style pass that runs nightly or on idle: identify Checkpoints where checkpoint A's coverage is a strict prefix of checkpoint B's; after a grace period of B remaining valid, drop A's payload (keep tombstone). Opt-in based on conversation age and checkpoint count — most conversations never need it.

A few things that are not options:

- **Never modify or delete entries in `rawEvents`.** Raw messages are the source of truth; they stay subject to the user's data-retention policy, never as an optimization.
- **Never prune the latest valid Checkpoint of a kind.** If you have only one valid checkpoint, keeping it is what makes incremental work possible. Don't drop it because it's "old."
- **Never prune across a branch point** without inheriting first. If a branch references a Checkpoint, that Checkpoint must remain reachable from at least one live conversation. Storage backends should track this with reference counts or at-archive-time GC.

For most personal-assistant scales, the storage cost of keeping all derived entries is modest — tens of checkpoints per long conversation, often under a megabyte total. Premature pruning trades reproducibility for an optimization you don't need at that scale. Reach for eager consolidation only after measuring real growth pressure.

### CRUD operations

Standard shape, RPC-able through the Communication Layer's control plane:

| Operation | Notes |
|---|---|
| `create(initial?)` | Returns a new conversation id; optional initial messages, mode, attachments, system prompt override |
| `read(id, opts?)` | Default: returns the conversation with `rawEvents` rendered as a message list. With `{includeDerived: true}` returns both arrays |
| `project(id, config?)` | On-demand projection — the message array the model would see now (or under an alternative config). Used by transparency UIs and debugging. Computed by the Context Engine |
| `latestValidCheckpoint(id, kind)` | Returns the latest valid Checkpoint of the given subtype (e.g., `CompactionCheckpoint`, `ToolResultTrim`). Used by the Engine to decide whether incremental work is possible |
| `update(id, patch)` | Patches metadata, mode, attachments, prompt overrides, routing — *not* messages (raw events are append-only via run operations; derived events are Context-Engine-owned) |
| `archive(id)` / `unarchive(id)` | Soft-archive without losing data. Triggers consolidation pruning of superseded checkpoints |
| `delete(id, mode: "soft" \| "hard")` | Soft-delete is recoverable for N days; hard-delete is irreversible |
| `list(filter)` | List with filters (tag, lifecycle, date range, full-text query); paged |
| `search(query)` | Full-text search across `rawEvents`; results scoped to owner |
| `branch(id, atMessageId)` | Create a new conversation forked at the given raw-message id. Inherits `rawEvents` through that point plus any Checkpoint whose coverage is entirely within the inherited prefix; in-flight state is not inherited |
| `invalidate(id, kinds?)` | Mark the latest Checkpoint(s) of the given kind(s) as superseded. Use when a known-bad checkpoint should be replaced explicitly rather than waiting for the next compaction to overwrite it |

All entries in this table are exposed on the Communication Layer's HTTP control plane *except* `latestValidCheckpoint(id, kind)`, which is an in-process call from the Context Engine and is intentionally not surfaced over the wire — clients that want checkpoints subscribe to `conversation/{id}/events` and filter to Checkpoint envelopes, or call `read(id, { includeDerived: true })`. `project(id, config?)` maps to `POST /conversations/{id}/projection` (POST rather than GET because the optional `config` is a full `AssemblyConfig` object passed in the body); `read(id, { includeDerived: true })` rides on `GET /conversations/{id}?includeDerived=true`. See [communication-layer.md](../communication-layer/) for the full endpoint table.

A design rule: the Conversation Manager's API is *operations on conversations*, not *messages and turns*. Sending input or running a turn happens through a separate run-oriented API (see "the run as a separate concern" below). Mixing them — e.g., a `sendMessage(id, content)` that also runs the turn — collapses two distinct lifecycles into one and makes streaming awkward.

### Branching: implementation choices

The architectural rules for branching are covered above in "Branching" — what gets inherited and the validity-check guarantees. This subsection covers the storage-layer implementation choice.

Two reasonable implementations:

- **Copy-on-branch** — the branch's events are physical copies of the parent's events through the branch point. Simple, allows independent storage paths, costs storage proportional to depth × breadth. The right default unless storage is a serious constraint.
- **Reference-shared prefix** — events 1..N are shared by reference; only divergent events are physical. More efficient, but every read of the branch has to walk the parent for the prefix and reference-counted GC becomes load-bearing for pruning.

Recommend copy-on-branch for the default backend. Conversations aren't usually huge enough for the storage difference to matter, and copy semantics make "what does this conversation contain" a single-table query.

The Manager publishes a `branched` event on both the parent's and the new conversation's lifecycle topic. Clients can render a tree view of related conversations from the `parentId` graph.

### Mode: chat vs agent (and possibly more)

`mode` is a property of the conversation, **owned by the Manager and read by other inner-ring layers** to alter behavior. The Manager doesn't enforce mode — it stores the value, runs transition hooks, appends a `ModeChangeMessage` to `rawEvents`, and publishes a `modeChanged` event on `conversation/{id}/state`. Each consuming layer (Tool System, Context Engine, Agent Runtime, Model Pool, Sub-Agent Pool) decides what its slice of the active mode means.

A first-class field on the conversation rather than a per-turn flag because switching mid-conversation is user-meaningful, history should reflect it, multi-client UIs need to render it, and sub-agents/branches need something to inherit. Per-turn settings belong in `runOptions`.

The recommended treatment is **mode as an id into a `ModeRegistry` of `ModeProfile` records** rather than a hard-coded enum, so adding a mode is registering a profile (not editing every consuming layer). For the full design — profile shape, per-layer slices, system-prompt assembly under modes, transition hooks, sub-agent inheritance, and the cross-cutting anti-patterns — see [modes.md](./modes.md). Planning specifically decomposes into three independently-adoptable concerns (constraint regime, plan artifact, progress tracking) layered on the mode machinery — see [planning.md](./planning.md).

### Attached resources

Files, URLs, datasets, screenshots — anything the user attached to give the conversation context. Each attachment carries:

- `id`, `kind` (`file` / `url` / `dataset` / `image` / `media`)
- `name`, `mimeType`, `size`
- `addedAt`, `addedBy` (`user` / `agent`)
- `trust` — defaults to `user-direct` for user-attached, `unknown-party` for agent-fetched (same trust enum as triggers)
- A reference to where the bytes live (persistence backend; not in the Conversation record itself for large files)

The Context Engine reads attachments at `assembleForTurn` time and decides what to include in the model context (whole file content, summary, search-only). The Manager doesn't read or transform attachments; it owns the metadata and the lifecycle. Add/remove are user operations through the Manager's API; the Context Engine asks the Manager for the current attachment list each turn.

The trust class on attachments is the part most easily missed. A user-uploaded file is `user-direct`. A file the agent fetched from the web is `unknown-party`. The Context Engine uses this to decide whether to envelope-wrap the content when injecting it into the prompt. Don't lose this distinction.

### Lifecycle

Conversations move through states; transitions are events:

```
created → active                          (initial)
active ⇄ suspended                        (idle eviction; reattach)
active → archived                         (user-initiated; read-only after)
archived → deleted                        (user-initiated soft-delete)
deleted → (purged after N days)           (background job)
```

- **Suspension** is for resource management. A conversation that hasn't received input in M minutes can be unloaded from in-memory state; reattaching reloads it. The user sees no difference; the server saves memory. Persistence keeps the on-disk state intact.
- **Archive** is user-meaningful: this conversation is done, hide it from defaults, but keep it. Read-only after archive (no new turns can run); read access still works.
- **Soft delete** preserves the data for a recovery window; hard delete (purge) is irreversible.

Each transition emits a lifecycle event the Communication Layer publishes onto `conversation/{id}/state` and `conversation/{id}/events`. The reference shape for the event taxonomy is a `session-lifecycle-events` module.

### Sub-agent runs as nested conversations

Per the [Sub-Agent Pool](../sub-agent-pool/) recommendation, delegate invocations are nested conversations. The Conversation Manager owns them the same way it owns user-initiated conversations:

- New `Conversation` record with `parentId` set to the parent conversation
- Same lifecycle, same persistence, same addressability
- Different `routing` defaults (often more restrictive tool whitelist, mode pinned to `agent`)
- The parent's run status references the child via `subagentRuns` if needed for UI

Why nested conversations rather than a separate "sub-agent run" record: it lets you reuse all the same machinery (CRUD, branching, attachments, lifecycle, event publishing) for free, and it makes "show me the full conversation tree" a single graph traversal. Two record types means two of everything.

The cost: the conversation list grows fast in agent-heavy workloads. The fix is to classify every conversation on two orthogonal axes — **lineage** (`root` / `branch` / `subagent`) and **origin** (`user` / `system`) — and derive catalog visibility from both, rather than keying off `parentId` alone. `parentId` is too blunt in both directions: a user-initiated branch *has* a parent but should stay visible, and a system-origin root like a trigger/automation host has *no* parent but should stay out of the user's primary list. Apply the derived filter at **every** read path — the REST `list()`, the agent-facing `list_conversations` tool, and the live catalog/registry event topic — not just `list()`. A classification any read path ignores leaks exactly the conversations it was meant to hide.

### The run as a separate concern

A *conversation* is a long-lived resource. A *run* is one execution of the agent loop within a conversation: input arrives → assistant streams → tools execute → loop terminates. Multiple runs happen across a conversation's lifetime; one run is in progress at a time.

The Manager exposes run operations distinct from conversation operations:

| Operation | Notes |
|---|---|
| `appendInput(conversationId, input, trustClass, runOptions?)` | Append user/trigger/channel input. If no run is in progress, start one. Returns a runId. |
| `cancelRun(conversationId, runId)` | Signal cancellation to the runtime. See [runs.md § Cancellation](./runs.md#cancellation-contract) |
| `getRun(conversationId, runId)` | State of a specific run (derived from `rawEvents` — see [runs.md § Runs as a derived view](./runs.md#runs-as-a-derived-view)) |
| `listRuns(conversationId)` | Run history for the conversation (derived from `rawEvents`) |

These four Manager operations map 1:1 to HTTP control-plane endpoints declared in [runs.md § External HTTP API](./runs.md#external-http-api): `POST /conversations/{id}/messages`, `POST /conversations/{id}/cancel`, `GET /conversations/{id}/runs/{runId}`, and `GET /conversations/{id}/runs`. The endpoint table in the [Communication Layer](../communication-layer/#recommendation) is the authoritative wire reference; precondition semantics, ETag scheme, and error responses are specified there.

**No `pauseRun` / `resumeRun`.** Deliberate user-driven run-pause is out of scope; `cancelRun` plus `appendInput` against the same `rawEvents` covers the use cases at much lower implementation cost. Pause-flavored mechanisms that *do* need first-class treatment — permission-gate pause/resume and crash/orphan recovery — are handled at the layers that own them. See [runs.md § Why deliberate pause/resume is out of scope](./runs.md#why-deliberate-pauseresume-is-out-of-scope) for the reasoning and OSS-corpus survey.

Distinguishing these from CRUD on the conversation itself keeps the lifecycles clean: CRUD operations are on the long-lived resource; run operations are on a specific in-flight execution.

The Manager hands `appendInput` off to the runtime by spinning up an `agentLoop(...)` invocation per the [agent-runtime.md](../agent-runtime/) spec. The Manager doesn't run the loop itself — it dispatches.

### Multi-client attach model

A conversation can have N attached clients, each with its own subscriptions. The Manager doesn't know about clients (the Communication Layer does), but it has to be designed *as if* it knows multiple consumers exist:

- **Snapshots are reproducible.** Any client that requests the conversation state should see the same snapshot regardless of when they connected.
- **Events are append-only and ordered.** Multiple clients consuming the same `conversation/{id}/events` topic see the same sequence of events, in the same order. Per-client filtering happens above.
- **State changes are atomic from the consumers' perspective.** A `modeChanged` event has the new mode in the `state` snapshot the moment after; no client should see the event without the corresponding state being updated.
- **Concurrent writes are serialized.** Two clients calling `update(id, patch)` simultaneously are serialized by the Manager; conflicting writes are detected and the second one returns a conflict error (with optimistic-concurrency semantics — pass an `expectedVersion`).

The hardest case: what if two clients both call `appendInput` while no run is in progress? The Manager has to pick a consistent rule. Recommend: serialize, both inputs queue into the same run, the runtime sees them as two consecutive turns. Surfacing "your input is queued behind another client's input" via Comm Layer event lets the user know.

### Persistence as a backend driver

The Manager has a backend interface; it doesn't own storage:

```ts
interface ConversationBackend {
  load(id: string, opts?: { sinceMessageId?: string; sinceCheckpointId?: string }): Promise<Conversation | null>
  saveMetadata(id: string, conv: ConversationMetadata): Promise<void>                 // everything except the two event arrays
  appendMessage(id: string, msg: Message, expectedLastMessageId: string): Promise<void>
  appendCheckpoint(id: string, ckpt: Checkpoint, expectedLastCheckpointId: string): Promise<void>
  pruneCheckpoints(id: string, checkpointIds: string[]): Promise<void>                // raw messages have no prune path
  query(filter: QueryFilter): AsyncIterable<ConversationSummary>
  search(text: string, owner: string): AsyncIterable<SearchHit>                        // indexes rawEvents only
}
```

Two distinct append paths reflect the two arrays. `appendMessage` is monotonic on `rawEvents` and uses optimistic concurrency on `expectedLastMessageId` — the runtime is the only writer for normal flow, so contention is rare. `appendCheckpoint` is monotonic on `derivedEvents` with its own optimistic-concurrency check; the Context Engine is the only writer, but multiple compactions can race (see "Concurrency"). `pruneCheckpoints` is the only mutation operation; it's restricted to `derivedEvents` and used at archive time and during periodic consolidation. Raw messages are never deleted by the backend — only the conversation lifecycle's hard-delete operation can purge them.

Search indexes `rawEvents` only — what users semantically search for. Derived entries are computed views; indexing them would surface the synthetic phrasing of summaries rather than what the conversation actually contained.

Backends include: SQLite (default for single-user / personal), Postgres (multi-tenant or larger), object storage with a metadata index (FTS5 SQLite for search is one good shape), in-memory (testing only). The natural physical model is two append-only tables (one for messages, one for checkpoints) joined to the conversation row by id; this maps directly onto the two-array shape. SQLite WAL mode, Postgres append tables, or a real event store like EventStoreDB all work — the architecture is storage-agnostic above the interface.

The Manager keeps a hot-cache of recently-accessed conversations in memory; cold conversations get evicted to the backend and reloaded on demand. The cache size is a config option; the eviction policy is LRU on `lastActiveAt`. For very long histories, `load(id, { sinceMessageId, sinceCheckpointId })` lets the Manager fetch incrementally — a hot client that already has the prefix just needs the tails of either array.

### Search across conversations

Cross-conversation search is a Manager operation that delegates to the backend's `search` method. The intent is to let a user find a past conversation by what was said in it — not by navigating a list, but by querying content. This surfaces history the way a person naturally recalls it: "find the conversation where I asked about X," not "open the conversation from Tuesday."

The Manager's `search()` API accepts a query and returns ranked hits scoped to the requesting account. The backend owns the index — the Manager doesn't know or care what indexing technology backs it. The interface that matters is:

```ts
search(text: string, owner: string): AsyncIterable<SearchHit>
```

**What to index.** Index `rawEvents` only — the user-visible messages, not derived checkpoints. Checkpoints contain synthetic phrasing from summaries and compaction outputs; indexing them surfaces the model's words, not the user's. If a user searches for "the flight booking I was doing," they want hits on their input and the assistant's direct responses, not on a compaction summary that rephrased the topic three turns later.

**Expected behavior.**

- Results are ranked, not just filtered. A query of "refactor the auth middleware" should surface the most relevant conversation at the top, not the most recent one that contains any of those words.
- Hits carry enough context to be actionable: the conversation ID, the matching message(s), and a brief excerpt with the match in context. The caller should be able to render a list of results without loading any full conversation.
- Search is scoped to the requesting account. A user never sees hits from conversations they don't own.
- Results should reflect the current state of the index at query time. A conversation that ended five minutes ago should be findable. Very recent in-flight content (mid-turn) is best-effort.

**Two search modes worth supporting.**

Full-text search handles "find conversations containing this word or phrase." Semantic search via embeddings handles "find conversations about this topic" — meaning-based rather than literal. The API can accept `{kind: "fulltext" | "semantic", query}`; the backend implements whichever it supports, and the Manager passes through without needing to know.

Most implementations ship full-text first and layer semantic in later. Don't defer the API shape — design it to support both modes from day one even if only one is implemented initially.

**Gotchas.**

- **Stale index after compaction.** When the Context Engine compacts a long conversation, the raw events it summarized remain in `rawEvents`, but a user reading the conversation later might only see the summary. The index should still hit on the original content — but callers should be aware that the full text they matched may no longer appear verbatim in the current view of the conversation.
- **Indexing latency.** Synchronous indexing on every message append is simple but serializes writes. Async indexing (write first, index in the background) keeps writes fast but means very recent messages may not be immediately searchable. Document which your backend does and what the lag expectation is.
- **Token-boundary mismatches.** Full-text indexing tokenizes at word or subword boundaries defined by the backend. Queries with punctuation, code identifiers (`auth_middleware`), or model-output formatting (backticks, markdown) may not match as expected if the tokenizer strips or splits them. Test search against realistic content — code-heavy conversations especially.
- **Relevance degrades on very long conversations.** A conversation with hundreds of turns is a very long document. Backends that rank by term frequency alone will surface long conversations over shorter, more relevant ones. Consider truncating the indexed content per-conversation or weighting by recency within a conversation.
- **Semantic search requires an embedding model.** This is an external dependency with its own latency, cost, and privacy implications. Content leaves the local process to be embedded. If the harness is privacy-sensitive or air-gapped, semantic search may not be viable.

**Implementation note.** If the backend is SQLite, FTS5 is a natural fit — it's built into SQLite and handles ranked full-text search well for this use case. FTS5-backed SQLite search is the most fully-realized approach. If the backend is Postgres, `tsvector` / `tsquery` covers the same ground. The choice is a backend concern; the Manager's API doesn't change.

### What the Manager publishes

Onto the Communication Layer:

- **`conversation/{id}/state`** — full state snapshot on subscribe; events on every state change (mode, lifecycle, attachments, prompt overrides, routing changes, run-status transitions, budget changes). State changes are metadata; they don't appear in `rawEvents` or `derivedEvents`.
- **`conversation/{id}/events`** — the live feed combining both persisted arrays *and* transient runtime progress, in arrival order. Three classes of envelope on this topic:
  - **Message envelopes** — appends to `rawEvents`. Concrete kinds: `InputMessage`, `AssistantMessage`, `ToolCallMessage`, `ToolResultMessage`. These are the history-rendering envelopes; what users see if they look at "the conversation."
  - **Checkpoint envelopes** — appends to `derivedEvents`. Concrete kinds: `CompactionCheckpoint`, `MemoryInjectionSnapshot`, `ToolResultTrim`, `SystemPromptAssembly`, `AttachmentDigest`. The Context Engine's work, visible to clients that subscribe; they don't change raw history.
  - **Runtime progress envelopes** — emitted by the Runtime *during* an in-flight turn (token deltas, content blocks, tool-call lifecycle, sub-agent spawn/result). These are *not* persisted to either array; they're transient events tagged with their owning runId. The completed assistant message lands as a single `AssistantMessage` envelope at the end of the run; the deltas have already streamed.
  - Subscribers filter for the rendering they want (history view filters to Message envelopes; transparency view subscribes to Checkpoint envelopes too; live UI takes the full stream). The `read(id, { includeDerived: true })` control-plane variant returns both persisted arrays; this topic is the live feed.
- **`conversations/registry`** — server-wide subscription to "what conversations exist for me" (filtered by account); events on create / archive / delete. Lower frequency.

---

## Alternatives

### Session as the unit (no branching)

A conversation is a flat thread; no branching, no parent/child. Simpler model.

**When this works:** when the user genuinely doesn't need to branch (most chatbot UX), or when branching is a UI illusion implemented client-side rather than as a real backend operation.

**Why not as default:** branching is the canonical "I want to try a different approach from here" gesture, and it's also the natural shape for sub-agent runs (which are branches of the parent conversation logically). Treating it as a primitive simplifies sub-agents and pays off in the UI.

### Single-tree threaded conversation (Slack-shaped)

Conversation as a single tree where every reply is a child of a specific message. No "branching" as a separate operation; replies fork.

**When this works:** when conversation shape is genuinely tree-shaped from the user's perspective — Slack thread workflows, Q&A bots.

**Why not as default for an agent harness:** model interactions are usually linear within a conversation (input → response → input → response), with branching as an explicit gesture rather than the default. The thread-shaped model adds UI complexity without matching how users use the agent.

### File-based conversation (each conversation is a file the user owns)

Conversations are markdown files in the user's filesystem; no separate persistence backend.

**When this works:** for a developer-facing CLI where the user wants conversations as artifacts they can grep, version-control, share, and edit. Some research-oriented workflows benefit.

**Why not as default:** the file format becomes load-bearing; every change to the conversation schema is a migration of every file; concurrent access requires file locking; search is grep-shaped (slow at scale). Workable for single-user dev tools; doesn't scale to a server-shaped harness.

A useful middle ground: persistence backend is database-shaped, but `export(id)` produces a markdown file the user can keep. Don't make the file the source of truth.

---

## Anti-patterns

- **Conversation owns the wire.** Methods named `subscribe`, `broadcast`, `disconnect`, types named `Client` / `Connection` on the Manager. The Comm Layer owns the wire; the Manager owns the resource. (See [communication-layer.md](../communication-layer/) for the full discussion.)
- **Connection-scoped conversation.** Conversation lives only as long as the client is connected. Reattach loses state; offline-then-reconnect starts fresh; mobile clients are unusable. The conversation is addressable by id and outlives any connection.
- **Single-client lock.** "Only one client can be attached to this conversation at a time." Forces every multi-device user to "release" before opening on another device, breaks shared / observed conversations, makes mobile + desktop simultaneous impossible. Allow N clients; serialize concurrent writes; let the UX handle "two cursors in one conversation."
- **Mutating the system prompt mid-turn.** A client changes the system prompt while a run is in progress; the half-completed turn now has inconsistent context. Either reject mid-run prompt changes (recommended) or mark them as taking effect on the next turn. Don't apply mid-stream.
- **Forking that re-runs the whole conversation.** Branching from message N should reproduce messages 0..N as-is, not re-execute them. If your branch produces different messages 0..N than the parent, you've conflated "branch" (fork at a point) with "re-run" (replay history with different inputs). They're different operations.
- **Conflating conversation and run.** A `sendMessage` operation that also blocks until the response completes. Tangles the conversation lifecycle with the run lifecycle; can't queue input behind a running turn cleanly; can't cancel without losing input.
- **Implicit cwd / user / context.** "The current conversation is whoever was most recently active." Module-level state that breaks the moment two clients are attached or two conversations are concurrently active. Address conversations by id; pass the id explicitly through every call. This bites hardest with background and sub-agent runs: a delegate executing against its *own* conversation id must never resolve "the current conversation" through a foreground selection pointer, or its tool calls silently target the user's active conversation instead of its own. Thread an explicit run scope (`{ selfId, parentId, rootId }`) into tool dispatch and let cross-thread tools opt into the root explicitly.
- **Persistence baked into the Manager.** Direct SQL calls or file I/O in the Manager's methods. Couples conversation logic to one storage shape; makes testing slow; blocks per-deployment backend swaps. Backend interface; inject implementation.
- **No optimistic concurrency on `update`.** Two clients patch the same conversation simultaneously; one silently overwrites the other. Pass `expectedVersion`; return conflict on mismatch.
- **Treating sub-agent runs as separate record types.** A `SubAgentRun` table parallel to `Conversation`. Now you have two of every machinery (CRUD, persistence, lifecycle events, search, etc.) and they drift. Sub-agent runs are conversations with `parentId` set.
- **Deriving catalog visibility from `parentId` alone.** "Hide anything with a parent" hides user-initiated branches that should stay visible, and *fails* to hide parent-less system conversations like trigger/automation hosts. Visibility is a function of two axes — lineage (`root` / `branch` / `subagent`) and origin (`user` / `system`) — not the presence of a parent. And the filter has to live at every read path (REST list, the agent-facing `list_conversations` tool, the live catalog/registry topic); one unfiltered path leaks every conversation the others hide.
- **Reclassifying a conversation after creation instead of at it.** Creating a sub-agent or trigger host as a default `user` / `root` conversation and then stamping its real lineage/origin in a follow-up write leaves a window where a concurrent `list()` sees it in the user catalog — and any creation seam that forgets the second write leaks it permanently. Stamp lineage and origin on the *first* insert; a visibility class is only as trustworthy as the creation paths that populate it.
- **Compaction mutating `rawEvents`.** Replacing raw messages 5-30 with a single "compacted message" inside `rawEvents`, deleting the originals. Looks tidy until you need to branch (the branch inherits the lossy state), debug ("what did the model see on turn 12 specifically?" — the originals are gone), recover from a bad summary ("the summarizer hallucinated; can we rerun?" — no), or upgrade to a larger model that doesn't need the compaction. `rawEvents` is the source of truth and stays strictly append-only; compaction emits a `CompactionCheckpoint` to `derivedEvents` whose payload describes the substitution. Same rule applies to tool-result trimming and every other transformation: never delete or mutate `rawEvents`; always emit a Checkpoint that the projection consumes.
- **Storing the projected view as the conversation's primary representation.** "We just save what we sent to the model on each turn." Compounds the previous anti-pattern with one extra harm: now you also can't reconstruct what the user *actually* said, because user inputs and tool results have been transformed before storage. `rawEvents` is the unedited record of what happened; the projection is computed from it.
- **Merging `rawEvents` and `derivedEvents` into one array with a kind discriminator.** Forces every consumer to filter on a discriminator and forces dynamic-typing patterns (`payload: Any`) in static languages where it's a real performance penalty. The two collections have genuinely different mutation rules, access patterns, cardinality, and storage shapes — surfacing that as two arrays with two protocols (`Message`, `Checkpoint`) makes the architecture honest and ports cleanly across languages. The temporal correlation is preserved by `Checkpoint.basedOnEventId`, which is a stronger anchor than interleaved insertion order anyway.
- **Letting any layer other than the Context Engine write to `derivedEvents`.** If the Manager, the Runtime, or a tool emits a `CompactionCheckpoint` or `MemoryInjectionSnapshot`, the validity guarantees fall apart — the config fingerprint won't match, the `basedOnEventId` may be stale, and stale checkpoints leak into the projection. `rawEvents` is written by runtime/users/tools through the Manager; `derivedEvents` is written only by the Context Engine. The Manager arbitrates the two append paths separately; the discipline of "Engine is the sole writer of derivedEvents" lives at that boundary.
- **Treating Checkpoints as authoritative without the validity check.** The projection function trusts a Checkpoint's payload only after the per-subtype validity check returns true. Skipping the check means a Checkpoint that was valid when written but isn't now (because of a branch divergence, a config change, or a memory-store update) silently feeds stale synthesis to the model. Always validate before substituting.
- **Writing in-flight Checkpoints to `derivedEvents`.** A compaction-in-flight that streams its synthesis token-by-token to the array is hard to reason about (partial state, cancellation rollback, race with foreground reads). The compaction completes in memory; the resulting `CompactionCheckpoint` is appended atomically as one entry. If cancelled, no entry is written; the previous latest valid Checkpoint remains the latest valid one.

---
