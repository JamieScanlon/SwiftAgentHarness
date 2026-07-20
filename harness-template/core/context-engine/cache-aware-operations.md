# Cache-aware operations

## TL;DR

Prompt caching makes the projected view a financial asset: an agentic loop re-sends the entire context every iteration, so whether the prefix re-reads from cache or re-writes into it is the dominant per-turn cost lever. The Engine is the layer that decides every byte the model sees, so the Engine owns cache effects. The core discipline is a **stability contract**: between deliberate cache events, each turn's projection must be a byte-extension of the previous turn's, and every transformation is classified as *cache-neutral* (appends), *cache-editing* (surgical, provider-supported), or *cache-breaking* (rebuild, budgeted and logged). On that contract sit three techniques: **surgical prefix edits** (`cache_edits` / `apiMicrocompact`-style deletion of stale tool results from a cached prefix without invalidating it, where the provider API allows), **TTL-aware pruning** (`contextPruning.mode = "cache-ttl"` — projection-only trimming of old tool-result blocks so the next cache *write* is smaller, transcript untouched), and **expiry inference** (past the provider TTL the cache is dead anyway; do all deferred hygiene for free). Breakpoint placement is a question the runtime *asks the provider binding*, never hardcodes. All of it runs through the standard Checkpoint machinery — fine-grained `ToolResultTrim` or coarse `CompactionCheckpoint`, same projection, different granularity.

---

## Recommendation

### Why this is an Engine concern

Provider prompt caches share one contract: the cached prefix must be **byte-identical** across calls, and a request pays a cache *write* premium (~1.25× on typical pricing) to make subsequent *reads* cheap (~0.1×). In an agentic loop the arithmetic is extreme — a 150k-token context re-sent over a 40-iteration turn is ~6M prompt tokens, of which all but the growing tail should be cache reads. One careless byte at position 10k re-prices the remaining 140k tokens from read to write, every iteration, silently: the request still succeeds, the reply is identical, only the invoice changes. At large-harness scale, cache-preserving context manipulation is measured in tens of billions of tokens per day.

Every layer contributes *content*, but only the Engine decides *bytes and their order* — so cache classification cannot be delegated to contributors. The system-prompt side of this discipline (stable prefix above a boundary marker, load-time-only contributions) is covered in [system-prompt-composition.md](./system-prompt-composition.md) and [providers § cache boundary](../../backends/providers/README.md#cache-boundary-and-prompt-contributions); this page covers the conversation side — the transformations that touch message history.

### The stability contract

State it as an invariant the Engine enforces, not a convention transformations follow:

> Between deliberate cache events, `project(rawEvents_n+1, derivedEvents_n+1, config)` must begin with `project(rawEvents_n, derivedEvents_n, config)` byte-for-byte.

Classify every transformation against it:

| Class | Behavior | Examples |
| ----- | -------- | -------- |
| **Cache-neutral** | Appends after the previous projection's end | New messages, tool results, below-boundary prompt suffix, late-placed memory blocks ([memory-injection.md](./memory-injection.md)) |
| **Cache-editing** | Modifies the prefix through a provider edit API that preserves cache validity | Surgical tool-result deletion (Technique 1) |
| **Cache-breaking** | Rebuilds the prefix; next request pays a full cache write | Compaction commit, mode switch, model change, memory-snapshot refresh at session start |

Cache-breaking events aren't forbidden — compaction *is* one, and it's the right trade — they're **budgeted and logged**. The ledger of allowed break events should be short, enumerable, and user-meaningful; anything breaking the prefix outside that ledger is a bug the observability section below is designed to catch. Determinism is a corollary of the contract: a trim that lands at a different offset depending on evaluation order produces a prefix mismatch that *looks* stable in code review. The projection being a pure function of `(rawEvents, derivedEvents, config)` is what makes the contract testable — assemble twice, compare bytes.

### Technique 1: surgical prefix edits

Where the provider API supports it, delete stale blocks *from inside the cached prefix* without invalidating the cache — the `cache_edits` / `apiMicrocompact` pattern. The canonical target is old tool results: a `read_file` result from forty iterations ago is dead weight the model no longer attends to, but it sits mid-prefix where ordinary deletion would break every byte after it. A cache-edit API tells the provider "the cached entry minus these spans," and the cache survives.

Engine mechanics are the standard ones: append a fine-grained `ToolResultTrim` Checkpoint per raw message being cleared; the projection substitutes the marker (`[Old tool result content cleared]`); `rawEvents` is untouched and the full result remains recoverable from the transcript. The *only* novelty is the transport — the trim is communicated to the provider as an edit rather than expressed as a rebuilt prefix.

Honesty requirement: **capability-gate this on the provider binding, and never fake it.** Most harnesses don't control an API surface with edit support. When the binding lacks the capability, the same `ToolResultTrim` checkpoints are still correct — they just take effect as a cache-breaking rebuild, which means the Engine should *batch* them (accumulate trims, apply at the next natural break event) instead of applying them eagerly. Applying prefix edits one-per-turn on a provider without edit support converts a cost optimization into a guaranteed full cache write per turn — the exact failure the technique exists to prevent.

### Technique 2: TTL-aware pruning (`contextPruning`)

A lighter pass than compaction, on a different cadence, with a different goal: **shrink the next cache write, not the context.** Provider caches expire (5-minute sliding TTL is the common default; some offer a long-TTL tier). When the cache entry is going to be re-written anyway — TTL about to lapse, or a natural break event pending — old tool-result blocks in the about-to-be-rewritten span are pure cost. The pruning pass trims them in the projection *before* the write happens:

```
contextPruning: {
  mode: "off" | "cache-ttl",
  ttlSeconds: 300,           // match the provider binding's cache TTL
  keepRecentToolResults: 5,  // never prune the working set
  targetTools: [...]         // heavy, stale-tolerant tools only
}
```

Three properties define it against compaction. It is **projection-only** — the on-disk transcript never changes (contrast compaction's persisted summary; pruning appends `ToolResultTrim` checkpoints, or for the most conservative variant, computes trims transiently at assemble time). It is **deterministic and free** — no LLM call, no summary, just marker substitution on old tool results. And it is **complementary, not competing** — pruning runs *between* compactions and defers to them; a session that prunes aggressively still compacts on the same thresholds. Auto-enable it for provider profiles with known TTL semantics; leave it off where the binding reports no caching (nothing to optimize) rather than letting it degrade tail quality for no benefit.

The tool-pair rule from [compaction.md](./compaction.md) applies unchanged: never trim a `tool_result` in a way that orphans its `tool_use` — the marker substitution preserves the pair structure, which is why pruning replaces content rather than deleting messages.

### Technique 3: expiry inference

The cheapest cache operation is noticing the cache is already dead. Track `lastRequestAt` per conversation; when the gap since the last model call exceeds the binding's TTL (with margin — a 2.5-hour threshold against a 5-minute TTL is the battle-tested shape, allowing for server-side grace), the next request pays a full cache write *no matter what the Engine does*. That's a free window: apply every deferred trim, run pending pruning, even trigger a due compaction — all the cache-breaking hygiene that was being politely deferred costs nothing extra now.

This inverts the usual discovery order. Without expiry inference, the harness learns the cache expired by paying the write and *then* wondering why; with it, the Engine front-loads the cleanup into the rebuild it was going to pay for anyway. Resumed sessions are the common case — a user returning after lunch should get a freshly-pruned, possibly freshly-compacted context at no marginal cache cost.

### Breakpoint policy: ask the binding

Where cache breakpoints land is provider knowledge, not Engine knowledge. The provider binding exposes `cacheTtlEligibility` and its caching model ([providers README](../../backends/providers/README.md)); the Engine supplies the *candidates*, the binding decides. The candidate set that serves explicit-breakpoint providers:

1. **End of the stable system prefix** — at the boundary marker. The big win; shared across every conversation on the same configuration.
2. **End of the tool schemas** — schemas are large and change only on registration events.
3. **A rolling conversation breakpoint** — near the tail, advanced as history grows, so each iteration re-reads the conversation body and writes only the delta.

For implicit-caching providers (automatic prefix caching, no breakpoint API), the candidate machinery is a no-op and the stability contract *is* the whole optimization. For providers with no caching, all of this quiesces — which is why every piece above is gated on the binding rather than global config. The counter-anti-pattern from the providers page bears repeating from this side of the seam: a runtime that places breakpoints without consulting the binding gets inconsistent savings and misattributes them to the Engine.

### Observability: cache regressions are silent

Nothing about a broken cache errors. The request succeeds, latency barely moves at small scale, and the invoice arrives later. So cache health must be *watched*, through the usage plane ([observability](../../cross-cutting/observability/README.md)):

- Record `cacheReadTokens` / `cacheWriteTokens` per model call, alongside the computed cost. **Cache hit rate per conversation-turn is the tuning metric** for everything on this page.
- Alert on the signature of a regression: cache *write* where the stability contract predicted a *read* — i.e., a prefix rebuild outside the break-event ledger. The Engine knows when it deliberately broke the prefix; an unexplained write is a contributor violating the contract, and catching it at emit time beats diffing invoices.
- Make it testable: a **cache-stability test** that runs two consecutive `assemble()` calls with an appended message and asserts byte-prefix containment catches most violations in CI, before they meet a bill.

---

## Alternatives

**No cache awareness.** Assemble the best context and let costs land where they fall. Correct for prototypes, low-volume harnesses, short sessions, and providers without caching — the machinery above has real complexity, and premature adoption of it obscures the projection logic it wraps. The upgrade path is incremental in exactly this page's order: stability contract first (it's mostly free — stop churning the prefix), then pruning, then expiry inference, and surgical edits only if the provider seam ever allows.

**Implicit-caching reliance only.** On providers that cache prefixes automatically, skip breakpoints and TTL machinery entirely and keep only the stability contract plus stability-ordered assembly. This is genuinely sufficient for those providers — the risk is portability, not correctness: the first deployment against an explicit-breakpoint provider silently gets zero caching until the candidate machinery exists.

**Restart-over-management.** Instead of surgically maintaining one long cached context, encourage shorter sessions: compact early, hand off via summary, start fresh (session-splitting per [compaction.md § resumability](./compaction.md#resumability)). Each fresh session pays one small cache write instead of managing a large decaying one. Defensible for task-shaped work with natural boundaries; it trades away long-session continuity, which is precisely what conversational harnesses can't give up.

**Aggressive always-prune (ignore TTL).** Prune old tool results on a fixed depth threshold every turn, cache be damned. Simpler than TTL tracking and *sometimes right* — if the working set genuinely fits in recent results, the context quality loss is nil. But unsynchronized with cache lifetimes it breaks the prefix mid-TTL (paying writes the "cache-ttl" mode would have avoided), and it throws away the recoverability cadence: TTL-aware pruning trims exactly when the write was coming anyway.

---

## Anti-patterns

- **Per-turn edits inside the cached prefix.** One contributor "refreshing" a timestamp, re-sorting a list, or updating a counter mid-prefix converts every subsequent token from cache read to cache write, every iteration, with no functional symptom. The stability contract exists to make this a detected violation instead of a billing surprise.

- **Faking surgical edits without provider support.** Applying eager per-turn prefix deletions on a binding with no edit API means paying a full rebuild each time while the code believes it's saving money. Capability-gate; batch trims to break events when the capability is absent.

- **Pruning that rewrites the transcript.** The trim is a projection concern; `rawEvents` stays lossless. A pruning pass that deletes tool results from persisted history breaks recovery, branching, and the audit trail to save disk space nobody was short of.

- **Nondeterministic trim placement.** Trims computed from wall-clock time, map iteration order, or mutable side state land at different offsets across assemblies of the same state — a prefix mismatch invisible in review. Trim decisions derive from `(rawEvents, derivedEvents, config)` like every other projection input.

- **Orphaning tool pairs.** Trimming a `tool_result` message away entirely (rather than marker-substituting its content) leaves a dangling `tool_use` the provider rejects. Same rule as compaction's boundary handling; content substitution, never message deletion.

- **Hardcoded breakpoints.** Breakpoint placement encodes provider knowledge — count limits, minimum cacheable sizes, TTL tiers. The runtime proposes candidates; the binding disposes. Hardcoding one provider's rules produces silently degraded caching on every other binding.

- **Treating pruning as compaction.** Pruning bounds the *cache write*, not the context. A session relying on pruning alone still grows toward overflow — the LLM summary, re-injection, and anti-thrashing machinery of [compaction.md](./compaction.md) remain load-bearing. Two passes, two jobs.

- **Refreshing "live" surfaces mid-session.** The memory snapshot, the skills index, a status line in the system prompt — each is a frozen-per-session surface precisely because refreshing it is a cache-breaking event per turn. The frozen-snapshot pattern ([memory.md](../memory/memory.md#agent-written-memory-the-frozen-snapshot-pattern)) is the general answer: disk now, prompt next session.

- **No cache accounting.** Without per-call read/write token metrics, a regression is indistinguishable from organic growth until someone audits the bill. The usage shape already carries the fields; record them and alert on unexplained writes.

---
