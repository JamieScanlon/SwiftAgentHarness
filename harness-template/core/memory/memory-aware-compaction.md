# Memory-aware compaction integration

## TL;DR

In-session compaction and durable memory are separate systems ([context-engine/compaction.md](../context-engine/compaction.md) vs. this area), but they meet at one critical moment: the summarizer is about to discard text that may contain the only copy of a durable fact. The recommended handshake is a **default-on, silent memory-flush turn before compaction**: when context crosses a soft threshold *below* the compaction trigger, run one agentic turn that tells the agent to append important notes to its **daily memory file** (`memory/YYYY-MM-DD.md`) — not `MEMORY.md` — with append-only and read-only safety hints enforced even on custom prompts, and a silent-reply token so the user sees nothing. Guard it with a **once-per-compaction-cycle counter** and a **context-hash dedupe** so repeated near-threshold turns don't spam duplicate memories. After compaction, **re-inject designated instruction sections** (from the project-instructions file) and optionally **re-sync the memory search index**. Let the active memory backend own the flush *policy* (prompt, thresholds, target path) via a plugin-resolvable flush plan, while the runtime owns the *trigger*; `before_compaction` / `after_compaction` hooks let other plugins observe the cycle.

---

## Recommendation

### The problem: compaction is a durable-state hazard

Compaction's contract is "preserve what matters in a bounded summary" — but a summary is lossy by definition, and the summarizer has no way to distinguish "fact the user will need next month" from "conversational detail." The [drift-handling](./memory.md#agent-written-memory-drift-handling) and [what-not-to-save](./memory.md#agent-written-memory-what-not-to-save) guard rails all assume durable facts eventually reach disk; compaction is the event that can destroy them first.

The fix is a **promotion step before the lossy step**: durable state gets flushed out of the conversation and onto disk *before* any text is summarized away. After the flush, the summarizer's failure modes stop being catastrophic — a mangled detail in the summary is an inconvenience, not a lost fact.

### Trigger: a soft threshold below the compaction threshold

The flush must fire *before* compaction does, which means its trigger sits below compaction's. Compute:

```
flushThreshold = contextWindow − reserveTokens − softThresholdTokens
run flush when totalTokens ≥ flushThreshold
```

with `softThresholdTokens` defaulting to ~4,000 — enough headroom that the flush turn itself (a model call plus a few file writes) completes before compaction actually triggers.

Add a second, independent trigger: **transcript size in bytes** (default ~2 MB, `0` disables). Token counts can be stale or unknown (fresh sessions resumed from disk, providers without usage reporting); a byte-size floor on the transcript catches sessions that are clearly long regardless of what the token accounting says.

Two failure modes need explicit guards:

- **Once per compaction cycle.** Record the compaction count at flush time; if the session's current compaction count equals the recorded one, a flush already ran for this cycle — skip. Without this, every turn between the soft threshold and actual compaction re-fires the flush.
- **Context-hash dedupe.** Hash the conversation tail (message count + content of the last few user/assistant messages, truncated SHA-256 is plenty). If the hash hasn't changed since the last flush, the context is effectively the same and flushing again would only produce duplicate memory entries — skip.

And one scheduling rule: **wait for idle**. The flush is an agentic turn on the same session; it must not run concurrently with an in-flight reply. Queue it behind the active run.

### The flush turn: silent, targeted, safety-hinted

The flush is one bounded agentic turn injected as a user prompt (plus an appended system-prompt section), with three properties:

**Silent.** The prompt ends with a silent-reply contract: "if nothing to store, reply with `<silent-token>`." The runtime enforces the token's presence in any custom prompt, suppresses partials that begin with it, and strips a glued leading token from tool-result text. The user never sees the flush happen; at most, a verbose-mode status line reports it.

**Targeted at the staging tier, not the index.** The flush writes **only** to the daily memory file (`memory/YYYY-MM-DD.md`, created if needed) — not `MEMORY.md`, not topic files. This matters for two reasons. First, a flush turn runs under time pressure with a nearly-full context; it is the *worst* moment to trust the agent with edits to curated files. Second, the daily file is exactly the staging tier that [background consolidation](./consolidation.md) later ranks and promotes — flush captures, consolidation curates. Capture at low quality-bar into an append-only staging file; promote at high quality-bar later, offline.

**Safety-hinted, enforceably.** Three hints ship in the default prompt *and are re-appended to any operator-customized prompt that omits them*:

1. *Target hint* — store durable memories only in `memory/YYYY-MM-DD.md`; use the canonical date-stamped filename (resolved in the configured timezone), never timestamped variants (`YYYY-MM-DD-HHMM.md`) that fragment the staging tier.
2. *Append-only hint* — if the daily file exists, append; never overwrite existing entries.
3. *Read-only hint* — treat the curated workspace files (`MEMORY.md`, the diary file, persona/instruction files) as read-only during the flush; never overwrite, replace, or edit them.

Enforcing hints on custom prompts is the detail worth copying: operators may rewrite the flush wording, but the invariants that protect curated memory survive the rewrite.

### Ownership split: backend owns policy, runtime owns trigger

When memory is a pluggable backend ([plugin-slot model](./memory.md#memory-as-a-single-active-plugin-slot-with-parallel-knowledge-layers)), the flush *policy* belongs to the memory plugin and the flush *trigger* belongs to the runtime. Model this as a **flush plan** the active backend registers a resolver for:

```
FlushPlan {
  softThresholdTokens      // how early to fire
  forceFlushTranscriptBytes // byte-size fallback trigger
  reserveTokensFloor       // shared with compaction's reserve accounting
  prompt                   // the flush user prompt
  systemPrompt             // appended system-prompt section
  relativePath             // flush target, e.g. memory/YYYY-MM-DD.md
}
```

The runtime asks "is there a flush plan?" at the soft threshold and executes whatever the plan says. A backend with no flush concept returns null and compaction proceeds bare. This keeps the runtime ignorant of memory-layout conventions and lets each backend put the flush where its own staging tier lives.

For lifecycle-hook backends (the [`on_pre_compress(messages)`](./memory.md#lifecycle-hooks-advanced) contract), there's a complementary integration on the *summarizer's* side: the hook extracts what it wants from messages about to be discarded, and its return value is included in the compression summary prompt. Flush-turn and pre-compress-hook are not exclusive — the flush moves state to disk; the hook enriches the summary.

### Post-compaction: restore what the summary can't carry

Compaction replaces the conversation's early history — including the reinforcement effect of instructions the model had been seeing all session. Two restore steps after the summary lands:

**Re-inject designated instruction sections.** Implemented in Context Engine re-injection: named H2/H3 sections from the nearest project `AGENTS.md` / `CLAUDE.md` (defaults `Session Startup`, `Red Lines`; legacy fallback `Every Session`, `Safety`). Config: `reinjectionInstructionSectionsEnabled`, `reinjectionInstructionSectionNames`, `reinjectionInstructionSectionMaxCharacters` (default 3000). Set `reinjectionInstructionSectionsEnabled: false` to disable. See [compaction.md § Re-injected attachments](../context-engine/compaction.md).

**Re-sync the memory index.** If the harness maintains a memory search index, offer a post-compaction sync mode: `off` / `async` (kick off in background) / `await` (block until synced). The flush turn just wrote new daily-file entries; an un-synced index means the next `memory_search` can't see the very facts that were saved to survive compaction. `async` is the right default; `await` is for harnesses where the next turn's recall correctness beats latency.

**Observability hooks.** Emit `before_compaction` / `after_compaction` plugin hooks around the whole cycle so memory plugins (and observability) can watch, annotate, or record cycle counts — without being able to block or rewrite the compaction itself. Observation is a hook; policy is the flush plan. Keep the two capabilities separate.

### What this buys the summarizer

With the handshake in place, responsibilities separate cleanly:

- **Durable facts** → flush turn → daily file → [consolidation](./consolidation.md) → `MEMORY.md`. Not the summarizer's job anymore.
- **Conversational continuity** (what we were doing, decisions, current state) → the summary. Its actual job.
- **Opaque identifiers** → identifier-preservation policy in the summarizer prompt ([context-engine/compaction.md § Identifier preservation](../context-engine/compaction.md)).
- **Standing orders** → post-compaction section re-injection.

Each loss channel gets a mechanism sized to it, instead of one summary prompt carrying every preservation duty at once.

---

## Alternatives

**Summarizer-prompt-only preservation.** No flush; instruct the summarizer to "preserve all important facts." The baseline most harnesses ship first. Cheaper by one model call per compaction cycle, but it concentrates all durable-state risk in a single lossy call, and there's no disk artifact to recover from when the summary drops something. Acceptable for short-session harnesses where durable memory barely accumulates; wrong once agent-written memory is load-bearing.

**Pre-compress hook only (no agentic flush turn).** The `on_pre_compress` backend hook extracts mechanically from the messages about to be discarded. No extra agent turn, deterministic cost — but extraction quality is limited to what backend code can pull without model judgment, and the output enriches the *summary* rather than landing in durable storage. Good fit for backends with strong structured extraction; most should pair it with the flush rather than replace it.

**Flush directly into `MEMORY.md` / topic files.** Skip the staging tier; have the flush turn write curated memory directly. Saves the consolidation step but puts the highest-stakes writes at the worst moment — near-full context, time pressure, no review. This is what the read-only hint exists to prevent. Defensible only in harnesses with no staging tier at all, and then only with the append-only discipline moved to `MEMORY.md` itself.

**Session-memory note as compaction aid.** The per-session templated note (see [memory.md § Alternatives](./memory.md#alternatives)) maintained by a forked subagent, preserving "Current State" across compactions. Solves a neighboring problem — continuity of the *session*, not durability of *facts* — and composes fine with the flush; it doesn't replace it.

---

## Anti-patterns

- **Flush threshold at or above the compaction threshold.** If the flush fires when compaction fires, the flush turn itself can overflow the context or race the summarizer. The whole point of the soft threshold is headroom; keep several thousand tokens between the two.

- **Re-flushing every turn near the threshold.** Between the soft threshold and actual compaction, every turn qualifies for a flush. Without the once-per-cycle counter and context-hash dedupe, the memory directory fills with near-identical daily-file entries — the flush becomes the noise source it was meant to prevent.

- **Letting the flush turn edit curated memory.** A time-pressured agent with a nearly-full context overwrites `MEMORY.md` with a "helpful" rewrite. Append-only to the daily staging file; curated files read-only during flush; hints enforced even on custom prompts.

- **Visible flush turns.** A user mid-conversation watching the agent suddenly announce "I've saved some notes to memory!" before every compaction reads as malfunction. Silent-reply token, enforced, with partial-suppression on the streaming path.

- **Flushing concurrently with an active reply.** Two agentic turns on one session interleave their tool calls and confuse the transcript. Wait for idle, then flush.

- **Token-only gating.** Sessions resumed from disk or running on providers without usage reporting can have stale or missing token counts, silently disabling the flush exactly where sessions are longest. The transcript-byte fallback trigger exists for this case.

- **Runtime-owned flush prompts.** Hard-coding the flush prompt and target path in the runtime couples it to one memory layout. The moment memory becomes pluggable, the flush plan must move behind the plugin boundary or every alternative backend inherits a flush that writes to the wrong place.

- **Skipping index re-sync.** The flush saves facts precisely so post-compaction turns can recall them; an index that doesn't know about the new entries defeats the sequence. Async re-sync after every compaction cycle.

- **Hooks that can block compaction.** `before_compaction` as a veto point lets a buggy plugin wedge every long session at its context limit. Observe/annotate only; compaction must always be able to proceed.

---
