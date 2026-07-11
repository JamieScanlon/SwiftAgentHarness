# Context Engine — Recommended Architecture

> Layer brief. Detailed designs (compaction, summarization techniques, prompt assembly) live in sibling pages: [compaction.md](./compaction.md) and [summarization-techniques.md](./summarization-techniques.md).

## TL;DR

The Context Engine owns **what gets sent to the model on each turn**. It reads the conversation's two event arrays (`rawEvents: [Message]` as the source of truth and `derivedEvents: [Checkpoint]` as the Engine's own prior work), the loaded skills, the attached resources, the relevant memory, and the per-conversation overrides; it applies the lifecycle of transformations (system-prompt assembly, history trimming, compaction, memory injection, tool-result trimming, attachment inlining); it returns a message array — the *projected view* the model will see. The projection is **a pure function of `(rawEvents, derivedEvents, config)`**: nothing is stored on the side, nothing is cached separately. The Engine's *only* persisted output is **Checkpoint** entries appended to `derivedEvents` (CompactionCheckpoint, MemoryInjectionSnapshot, ToolResultTrim, optional SystemPromptAssembly, optional AttachmentDigest); each carries a validity check so stale or invalidated entries can be silently rejected.

The architectural lock-in for this layer: **never mutate `rawEvents`.** Raw history stays append-only and lossless; everything the Engine produces is a Checkpoint in `derivedEvents`, with its own validity check. See [conversation-manager.md → "The event log and the projected view"](../conversation-manager/README.md#the-event-log-and-the-projected-view) for the full type and the projection function.

The lifecycle shape: `bootstrap / ingest / assemble / compact / afterTurn` plus optional `prepareSubagentSpawn / onSubagentEnded`. This is the recommended factoring for "swap out the entire context strategy" as a plug point. Each step appends Checkpoints (where applicable) rather than mutating side state.

---

## Why this belongs as its own layer

Without a Context Engine, every concern that wants to mutate the outgoing message array fights every other concern that wants to mutate it: compaction, memory injection, system-prompt overrides, tool-result trimming, attachment handling, skill discovery. Each is a reasonable feature in isolation; together they produce a 1,500-line `assembleMessages()` in the runtime that nobody can refactor.

The Engine exists so all of these concerns plug into one defined lifecycle, the runtime calls one method (`project(...)`), and the resulting message array is reproducible from `(rawEvents, derivedEvents, config)`. Three failure modes the lifecycle prevents:

1. **Order-of-operations bugs.** Compaction has to run before memory injection (you don't want to compact memory hits along with the conversation), but trimming has to run after both. Without a defined order, transformations clobber each other depending on registration order.
2. **Silent raw-event mutation.** The shortest path from "we need more context budget" to "OK, summarize and replace messages 5-30 in `rawEvents`" is one developer thinking it's harmless. Once it's done, branching is broken, transparency is broken, recovery is broken. The two-array pattern is the institutional discipline that prevents this — Checkpoints are additive in `derivedEvents`, not destructive in `rawEvents`, and the validity check makes them safe to ignore when stale.
3. **Per-call duplication.** The runtime calls the Engine every iteration; the Engine walks `derivedEvents` and reuses prior work via `latestValidCheckpoint(...)`. Without the layer, every call site re-decides whether to re-summarize, re-fetch memory, re-resolve skills.

---

## Recommendation (overview)

Detailed designs are in sibling pages. This README is the architectural framing.

### Two-array event log with projection as the canonical implementation

Every transformation the Engine performs follows the same pattern:

1. **Read the conversation's two arrays** — `rawEvents: [Message]` (source of truth) and `derivedEvents: [Checkpoint]` (Engine-owned, supersedable).
2. **Walk `derivedEvents` newest-first**, using `latestValidCheckpoint(derivedEvents, Kind, rawEvents, currentConfig)` to find the most recent valid Checkpoint of each relevant subtype (CompactionCheckpoint, MemoryInjectionSnapshot, ToolResultTrim, …). The validity check is per-subtype but shares the shape — prefix or anchor match (the raw messages the Checkpoint was based on still appear unchanged at the head of `rawEvents`) plus config-fingerprint match (the policy that produced it still applies).
3. **Project**: `project(rawEvents, derivedEvents, config) → [Message]` — synthesize the message array the model will see by substituting Checkpoint payloads for the raw messages they cover, and applying late-stage transformations (memory injection, attachment inlining, system-prompt assembly).
4. **If a transformation needs to do new expensive work** (run the compaction LLM, fetch new memory hits, summarize a fresh tool result), do it, then **append a new Checkpoint** to `derivedEvents` via `Manager.appendCheckpoint`. The next call sees it via `latestValidCheckpoint`.

This pattern is how compaction, memory injection, tool-result trimming, and (optionally) system-prompt assembly are all implemented. Each has its own Checkpoint subtype with its own payload shape; they share the projection machinery and the validity-check discipline.

### Per-transformation specifics

- **The lifecycle** — `bootstrap / ingest / ingestBatch / assemble / compact / afterTurn`. `assemble()` returns `{messages, estimatedTokens, systemPromptAddition?}` — the projected view for the upcoming turn. Optional `prepareSubagentSpawn / onSubagentEnded` for sub-agent coordination.
- **`project(rawEvents, derivedEvents, config)` is the pure-function entry point the [Agent Runtime](../agent-runtime/) calls every iteration via the Manager's `assembleForTurn(...)` wrapper.** No side state; same inputs always produce the same output.
- **Compaction appends a `CompactionCheckpoint` to `derivedEvents`** whose payload describes how to substitute a synthetic message list for a covered raw-message prefix. See [compaction.md](./compaction.md) for triggers, scope, prompt design, output framing, and the validity rule. Compaction never mutates `rawEvents`.
- **Memory injection appends a `MemoryInjectionSnapshot` to `derivedEvents`** when the Engine fetches relevant memory and wants to cache the lookup across turns. The validity check covers both raw-prefix match and the memory store's `memoryStoreVersion` (so an updated memory invalidates cached snapshots automatically). Late-stage transformations apply the snapshot's hits to the projection. See [memory-injection.md](./memory-injection.md) for the full injection policy: tiers, thresholds, budgeting, placement, and ordering.
- **Tool-result trimming appends a `ToolResultTrim` to `derivedEvents`** targeting a specific raw `ToolResultMessage` by id. The projection substitutes the trimmed view when assembling. Validity check is just "the target message still exists" (always true given raw messages are immutable; trims never invalidate without explicit replacement).
- **Attachment inlining is a per-turn representation decision** — inline / digest / reference, chosen from size, modality × model capability, trust class, and recency; attachment bytes never enter `rawEvents`, and expensive digests are cached as `AttachmentDigest` Checkpoints keyed on content hash. See [attachment-inlining.md](./attachment-inlining.md).
- **System-prompt assembly is normally transient** — computed once per turn, not persisted — but can optionally append a `SystemPromptAssembly` Checkpoint for transparency/debugging UIs that want to render "what was the system prompt on turn 17." See [system-prompt-composition.md](./system-prompt-composition.md) for the full composition design: named sections, layering, cache-boundary discipline, sub-agent scoping.
- **`ownsCompaction: true` disables the runtime's auto-compaction**; `delegateCompactionToRuntime(...)` lets engines opt back in. This is the seam that makes the entire compaction strategy pluggable.
- **Pluggable engines via a single plugin slot** (`plugins.slots.contextEngine`). The cleanest "swap out the entire context strategy" point in the six harnesses.
- **Cache-aware operations.** Edit the projected prefix surgically so prompt caches survive context manipulation (the `cache_edits` / `apiMicrocompact` technique; a `contextPruning.mode = "cache-ttl"` pass drops old tool-result blocks before the prompt-cache TTL expires). Implementations either append fine-grained `ToolResultTrim` Checkpoints for the specific raw messages being pruned or append a coarse `CompactionCheckpoint` covering a larger range — same projection machinery, different granularity. See [cache-aware-operations.md](./cache-aware-operations.md) for the full design: stability contract, the three techniques, breakpoint policy, cache observability.

### Concurrent compaction

The Engine may be triggered to compact from multiple paths: the runtime sees context filling up; a background memory-consolidation job decides it's time; a client explicitly calls "compact this conversation now." Without coordination, two compactions can produce wasted work and ambiguous ordering on `derivedEvents`.

The recommendation, fully covered in the [Conversation Manager's "Concurrency and the compaction lock"](../conversation-manager/#concurrency-and-the-compaction-lock) section:

- Per-conversation compaction lock — single in-flight compaction per conversation; other attempts no-op return the existing latest valid `CompactionCheckpoint`.
- Coverage-range idempotency — attempts that would cover the same range with the same config fingerprint are short-circuited.
- Foreground turns never block on compaction commit — they project against the arrays as they exist now, ignoring the in-flight one.
- Optimistic write at the `derivedEvents` boundary — `basedOnEventId` plus a "no conflicting Checkpoint of this kind has landed since" check on `appendCheckpoint`.

What the Engine implements directly: the lock-and-skip behavior, the coverage-range comparison, and the optimistic-write conflict handling. Foreground non-blocking is a property of *not consuming an in-flight compaction's result* — by walking only the persisted `derivedEvents` array, the runtime naturally sees only committed Checkpoints, which is the correct behavior.

`rawEvents` has its own concurrency model — runtime is the natural single writer (one in-flight run per conversation), so contention is rare and standard optimistic concurrency on `expectedLastMessageId` suffices.

### Pruning of derived events

`derivedEvents` grows with each compaction trigger, each memory snapshot, each tool-result trim. Checkpoints that are strictly subsumed by later ones become redundant. Pruning is for `derivedEvents` only — `rawEvents` is never pruned.

Layered strategy, described in detail in the [Conversation Manager's "Pruning"](../conversation-manager/#pruning) section:

- **At archive time, consolidate.** When a conversation moves to `archived`, find the latest valid Checkpoint of each subtype, verify subsumption, drop superseded payloads (keep tombstone entries in `derivedEvents` if you want replay).
- **At branch time, filter.** Branch creation only inherits Checkpoints whose coverage falls entirely within the inherited raw prefix.
- **Optionally: periodic background consolidation** for very long-running conversations.

Two operational rules the Engine must respect: **never prune the latest valid Checkpoint of a kind** (that's the one making incremental work possible), and **never prune across a branch point** without inheritance bookkeeping (a Checkpoint a branch references must remain reachable from at least one live conversation).

---

## What consumes the Context Engine and what it consumes

**Consumers (callers):**
- The [Agent Runtime](../agent-runtime/) calls `project(...)` every iteration via the Manager's `assembleForTurn(...)` wrapper.
- The [Conversation Manager](../conversation-manager/) calls the Engine to compute on-demand projections via `project(id, config?)` for transparency UIs and debugging.

**Reads from:**
- The [Conversation Manager](../conversation-manager/) — both `rawEvents` and `derivedEvents`, plus the conversation state (mode, prompt overrides, attached resources, routing, budget).
- The [Memory layer](../memory/) — cross-conversation knowledge worth injecting. Memory is an inner-ring peer (not a registry) because the Context Engine auto-loads from it on every turn without the model invoking it.
- The Skills registry (a Tool System concern — see [../tool-system/](../tool-system/)). The Context Engine reads only the *index* of available skills (names + descriptions) for system-prompt listing; the skill *content* is loaded by the model invoking the `Skill` tool, and arrives as a tool result (becoming context on the next turn).
- The active model's capability metadata (from the [Model Pool](../model-pool/)) — needed to decide compaction aggressiveness, prompt-cache breakpoints, attachment inlining policy.

**Writes to:**
- The [Conversation Manager](../conversation-manager/) — `derivedEvents` only, via `appendCheckpoint(...)`. The Engine is the sole writer of Checkpoint kinds (CompactionCheckpoint, MemoryInjectionSnapshot, ToolResultTrim, optional SystemPromptAssembly, optional AttachmentDigest). Never writes to `rawEvents`.

---

## Sibling pages in this folder

- [compaction.md](./compaction.md) — Recommended design for compaction: triggers, scope, prompt design, output framing, resumability. Drafted.
- [summarization-techniques.md](./summarization-techniques.md) — Beyond full compaction: deterministic pre-compaction hygiene, turn-prefix summarization, branch summarization, iterative/delta summarization, focused compaction.
- [memory-injection.md](./memory-injection.md) — Injection policy: the three-tier ladder (frozen index snapshot / per-turn relevance pass / pre-reply recall), bias-toward-nothing thresholds, memory-junior-to-conversation budgeting, placement and fencing, `MemoryInjectionSnapshot` caching, ordering against compaction and trimming.
- [system-prompt-composition.md](./system-prompt-composition.md) — The prompt as a structured artifact of named sections: single-owner sections, contribution-not-mutation, the six-layer precedence order, four levers (directive / suppression / override / full override), cache-boundary discipline, sub-agent recompose-vs-fork, override-proof Constraints, `SystemPromptAssembly` auditability.
- [cache-aware-operations.md](./cache-aware-operations.md) — The stability contract (byte-extension between deliberate cache events; transformations classed cache-neutral / cache-editing / cache-breaking), surgical prefix edits, TTL-aware pruning, expiry inference, breakpoint policy as a provider-binding question, cache-regression observability.
- [attachment-inlining.md](./attachment-inlining.md) — The inline / digest / reference ladder chosen per attachment per turn: smallest-sufficient-rung selection, recency demotion, bytes-never-in-`rawEvents`, `AttachmentDigest` Checkpoint caching, trust wrapping at every rung, compaction touchpoints.

---
