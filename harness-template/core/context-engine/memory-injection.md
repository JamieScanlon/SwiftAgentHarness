# Memory-injection policy

## TL;DR

The [Memory layer](../memory/) owns *storage and retrieval*; the Context Engine owns *injection policy* — when memory enters the prompt, where it lands, how much budget it gets, and how the lookup is cached. The recommended design is a **three-tier injection ladder**: (1) an always-loaded **index snapshot** frozen into the system prompt at session start; (2) a **per-turn relevance pass** that surfaces up to 5 topic files as a fenced, untrusted block, cached across turns via a `MemoryInjectionSnapshot` Checkpoint whose validity covers `memoryStoreVersion`; (3) opt-in **pre-reply blocking recall** for conversational surfaces. Bias every tier toward injecting *nothing* — the failure mode that kills memory features is noise, not misses. Budget memory as **junior to the conversation tail**: when context is tight, drop per-turn hits before trimming conversation, but never drop the index. Order matters: compaction runs before injection (never compact memory hits), trimming runs after both.

---

## Recommendation

### Ownership: the Memory layer retrieves, the Context Engine decides

Memory injection sits on the boundary between two layers, and the split must be explicit or the policy ends up implemented twice (or zero times):

- The **Memory layer** owns the store, the search pipeline (`memory_search`, hybrid detection, the relevance selector's retrieval mechanics), and the content itself. See [memory.md](../memory/memory.md).
- The **Context Engine** owns the injection *policy*: whether this turn gets an injection pass at all, where the results land in the projected view, what token budget they may consume, how the lookup is cached (`MemoryInjectionSnapshot`), and how injection orders against compaction and trimming.

The practical test: "should sub-agents get memory?" is a Context Engine question; "did hybrid search silently degrade to lexical-only?" is a Memory question. Debugging follows the same split — recall-quality complaints usually trace to the retrieval backend, injection-noise complaints to the policy layer.

### The injection ladder

Three tiers, cumulative, each with a different cost profile and trigger:

**Tier 1 — always-loaded index (session start).** The `MEMORY.md` index (≤200 lines / 25 KB, per [memory.md § recall](../memory/memory.md#agent-written-memory-recall)) plus project-instruction files enter the system prompt as a **frozen snapshot** captured at session start. Mid-session memory writes hit disk but do not refresh the snapshot — this is the [frozen-snapshot pattern](../memory/memory.md#agent-written-memory-the-frozen-snapshot-pattern), and it exists to preserve the prompt-cache prefix for the whole session. Tier 1 is unconditional for eligible sessions: it is cheap, deterministic, and gives the model the *map* of what memory exists.

**Tier 2 — per-turn relevance pass.** On user turns, a cheap-model selector (or heuristic scorer below ~30 topic files) takes the incoming message plus the topic-file *headers* — never bodies — and returns up to 5 files worth surfacing. The Engine injects those files' contents as a late-stage transformation on the projection and appends a `MemoryInjectionSnapshot` so subsequent iterations of the same turn (tool-call loops) reuse the lookup instead of re-selecting. Tier 2 runs on **user turns only** — not on every runtime iteration, not on tool-result continuations, and never inside the extraction or compaction sub-agents.

**Tier 3 — pre-reply blocking recall (opt-in).** For conversational surfaces where continuity is the product, the bounded recall sub-agent from [pre-reply-recall.md](../memory/pre-reply-recall.md) adds one guaranteed judgment-bearing retrieval per turn. The Engine's involvement is placement and gating: the summary enters as a fenced hidden prefix, and the eligibility conjunction (interactive, persistent, direct-chat, allowlisted agent) is enforced before the sub-agent is ever spawned.

Task-oriented harnesses ship Tiers 1–2 and stop. Tier 3 is a conversational enrichment with a per-turn latency bill; adopt it deliberately.

### When to inject — and when not to

Injection eligibility is a conjunction the Engine evaluates in `assemble()`:

- **User-initiated turns only** for Tiers 2–3. Heartbeats, scheduled runs, and headless one-shot invocations get Tier 1 at most — hidden personalization in automation surprises operators and wastes selector calls.
- **Main agent only, by default.** `prepareSubagentSpawn` should *not* propagate per-turn memory hits into sub-agent contexts. Sub-agents get a task-shaped slice of context from their spawner; if the task needs a memory fact, the spawner puts it in the task description. The one exception is deliberate: a sub-agent type explicitly configured with memory access (and the recall sub-agent itself is a *consumer* of the memory tools, not a target of injection — recursive injection is the classic waste case).
- **Skip on re-selection no-ops.** If the latest valid `MemoryInjectionSnapshot` covers the current raw prefix and the store version is unchanged, there is nothing to decide — project the cached hits. New selector calls happen only when the user has said something new or the store has changed.

### Relevance threshold: bias toward nothing

Every tier needs an explicit "inject nothing" outcome, and the policy should make that outcome *easy*:

- The selector prompt says it plainly: "if you're unsure, don't include it." Weak, speculative, or vaguely-related matches are excluded, not ranked low.
- Cap hits at 5 files regardless of how many clear the threshold — past that point the model stops attending to any of them.
- Filter hits the conversation already covers: usage-reference memories for tools the conversation is actively exercising are redundant (though *gotcha* memories about those same tools are exactly what to keep — active use is when they matter).
- For score-based heuristic backends, set the threshold so that an empty result is common. A memory feature that injects something every turn has its threshold wrong.

The asymmetry is deliberate. A missed injection costs one turn of slightly-less-informed reply, and the model can still consult the Tier-1 index and read the file itself. A noise injection costs attention on every turn it recurs, and enough of them get the feature disabled.

### Budgeting: memory is junior to the conversation

Fixed caps per tier, and an explicit seniority order when the assembled prompt is tight:

| Surface | Default cap | Seniority |
| ------- | ----------- | --------- |
| Tier 1 index | 200 lines / 25 KB (memory layer's cap) | Senior — never dropped |
| Project-instruction files | ~40 KB per file, head/tail truncated | Senior — never dropped |
| Tier 2 hits | 5 files, ~4 KB each, ~16 KB total | Junior — dropped before conversation trimming |
| Tier 3 summary | 220 chars | Effectively free |

The seniority rule is the load-bearing decision: **when the projection exceeds budget, shed Tier 2 hits before trimming conversation history, and shed lowest-relevance-first.** Memory hits are re-derivable — the store is on disk and the index is still in the prompt — while trimmed conversation is gone until someone reads the archive. The inverse policy (protecting memory hits while compacting conversation harder) quietly converts the context window into a memory cache and starves the actual task.

One consequence worth stating: injection must never trigger compaction. If adding memory hits would push the prompt over the compaction threshold, drop hits. A compaction pass whose proximate cause was memory injection is the system fighting itself.

### Placement and fencing

Each tier has one correct landing zone in the projected view:

- **Tier 1** → system prompt, inside the standard framing ("codebase and user instructions are shown below…"). It is configuration-like, stable for the session, and belongs in the cached prefix.
- **Tier 2** → a **fenced, untrusted block** injected late in the projection (after conversation history, before or attached to the latest user message), using the `<memory-context>` fence and framing line from [memory.md § lifecycle hooks](../memory/memory.md#lifecycle-hooks-advanced). Never as a visible user or assistant message — recalled memory rendered as conversation text confuses both the model (it reads as something the user said) and the transcript (branching and replay now contain synthetic turns).
- **Tier 3** → the hidden prompt prefix with the untrusted fence from [pre-reply-recall.md § injection](../memory/pre-reply-recall.md#injection-fenced-hidden-untrusted).

Three invariants shared by every placement: **hidden** (fence tags never reach the client-visible reply), **fenced** (explicit tags plus a framing line demoting the content below instructions — memory is agent-written historical data, not a command channel), and **sanitized** (strip fence-tag lookalikes from memory content before wrapping, so a stored entry can't smuggle a closing tag and instruction-shaped text into the prompt).

### Caching: the `MemoryInjectionSnapshot` Checkpoint

The per-turn lookup is expensive relative to projection, so its result is persisted as a Checkpoint in `derivedEvents` — the Engine's standard machinery (see [README § two-array event log](./README.md#two-array-event-log-with-projection-as-the-canonical-implementation)):

```
MemoryInjectionSnapshot extends Checkpoint {
  hits: MemoryReference[]        // file ids + resolved content hashes
  memoryStoreVersion: string     // store version at lookup time
}
```

Validity is the standard shape plus one extra term: raw-prefix match (the messages the lookup was based on are unchanged) **and** config-fingerprint match (same selector policy) **and** `memoryStoreVersion` match. The version term is what makes user edits behave correctly: the user runs `/memory`, fixes a stale entry, the store version bumps, every cached snapshot silently invalidates, and the next turn re-selects against the corrected store. Without it, cached hits keep projecting the pre-edit content for the rest of the session.

Note the intentional asymmetry with Tier 1: the *index snapshot* deliberately ignores store changes (frozen for cache stability), while *per-turn hits* deliberately track them (freshness matters more than the few hundred tokens of cache the late-placed block would have saved). Late placement is what makes this cheap — Tier 2 content sits after the cached prefix, so invalidating it costs re-encoding a block, not rebuilding the prompt cache.

### Ordering against compaction and trimming

The lifecycle order from the [README](./README.md#why-this-belongs-as-its-own-layer) exists largely for memory injection's benefit:

1. **Compaction first.** The summarizer sees only conversation, never injected memory blocks. Compacting memory hits along with the conversation bakes recalled content into the summary — after which it can't be invalidated by `memoryStoreVersion`, can't be shed under budget pressure, and survives even if the user deletes the underlying memory.
2. **Injection second**, against the post-compaction projection. Post-compaction is also when the Engine re-applies what the summary can't carry — cross-ref the re-injection and index-resync steps in [memory-aware-compaction.md § post-compaction](../memory/memory-aware-compaction.md#post-compaction-restore-what-the-summary-cant-carry).
3. **Trimming last**, with the seniority order above.

One guard completes the loop: the selector must not re-surface content that earlier injected blocks already carry (the feedback-loop guard from [pre-reply-recall.md](../memory/pre-reply-recall.md) generalizes — recall output in turn N is visible context at turn N+1, and without an explicit dedupe the pipeline re-recalls its own echoes). Dedupe by memory file id across the currently-projected injection blocks.

---

## Alternatives

**Always-inject top-K (RAG-style), no threshold.** Run vector search every turn, inject the top K hits unconditionally. Simpler — no selector call, no judgment — and wrong for the same reason it's simple: no `NONE` outcome means marginal matches land every turn, which is precisely the noise profile that erodes trust. Acceptable only where memory volume is tiny and uniformly high-quality (early-life harnesses), and even then the cap-and-threshold version costs almost nothing more.

**Reactive-only (no injection beyond the index).** Tier 1 plus the model's own `memory_search`/read calls; no per-turn pass at all. Strictly cheaper and fully cache-stable; the right floor for task-oriented harnesses where the work itself prompts the lookups. The failure mode is conversational: memory the model had no task-shaped reason to search for never surfaces. This is the baseline the ladder's Tiers 2–3 upgrade.

**Live memory view via cache breakpoint.** Instead of freezing the Tier-1 snapshot, place a provider cache breakpoint at the memory boundary so the static prefix stays cached while the memory section re-encodes when it changes. Keeps the model's view of memory live mid-session at the cost of provider-specific breakpoint management. Defensible on providers with cheap fine-grained breakpoints; the frozen snapshot remains the recommended portable default.

**Everything-always-loaded.** Below ~20–30 topic files, skip Tiers 2–3 and load all topic bodies with the index. Zero selector cost, zero misses, fully cacheable. It has a cliff, not a slope — plan the migration to the selector before volume reaches it, because the symptom (prompt bloat displacing conversation) appears gradually and gets misattributed.

---

## Anti-patterns

- **Injecting memory as visible conversation messages.** Recalled content rendered as a user or assistant turn pollutes the transcript (branch/replay now contain synthetic messages) and misleads the model about who said what. Injection is a projection-time transformation; `rawEvents` never contains injected memory.

- **Refreshing the Tier-1 snapshot mid-session.** Every refresh invalidates the prompt-cache prefix for a marginal freshness gain the frozen-snapshot pattern deliberately trades away. Writes surface next session; the write confirmation (tool result or diff) covers the current one.

- **Compacting injected memory blocks with the conversation.** Once recalled content is baked into a summary it is unsheddable, uninvalidatable, and outlives the memory it came from. Compaction scope is conversation only; injection re-applies afterward.

- **Memory displacing the conversation tail.** Under budget pressure, hits go first — they're re-derivable from disk. A projection that keeps five memory files while trimming the user's last exchange has the seniority order inverted.

- **No `memoryStoreVersion` term in snapshot validity.** User edits a memory; cached snapshots keep projecting the stale content for the rest of the session. The version term is the difference between "memory editing works" and "memory editing works next session, maybe."

- **Unfenced or trusted injection.** Unfenced recall reads as user input; unsanitized recall can smuggle fence tags or instruction-shaped text. Fence, frame as untrusted, strip tag lookalikes — for every tier, every time.

- **Injecting into sub-agents and background runs by default.** Extraction sub-agents, compaction summarizers, heartbeat runs, and spawned task agents all have narrower context contracts. Injection eligibility is an explicit conjunction, and sub-agent spawn paths default out.

- **Cross-tier double-injection.** The index lists a file, the selector injects its body, and the Tier-3 summary paraphrases it again — three copies of one fact competing for attention. Dedupe hits by file id across all currently-projected memory surfaces.

- **Selector reads topic bodies.** The selector operates on frontmatter headers only; that's what keeps its cost flat as memory grows to hundreds of files. A body-reading selector re-introduces the prompt-bloat problem the index/topic split was designed to solve.

- **Injection triggering compaction.** If adding hits would cross the compaction threshold, the correct move is fewer hits, not a compaction pass. Memory is an enrichment; it must never be the proximate cause of a lossy operation on the conversation.

---
