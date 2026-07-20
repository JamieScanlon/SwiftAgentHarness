# Background consolidation (dreaming)

## TL;DR

Layer an **opt-in, cron-scheduled consolidation sweep** over agent memory once it accumulates for months. The recommended model — **dreaming** — runs three phases sequentially in one sweep (**light → REM → deep**); only the deep phase writes durably, and its only durable target is `MEMORY.md`. Candidates are ranked by six weighted recall-derived signals plus phase-reinforcement boosts, gated by hard thresholds (`minScore` 0.75, `minRecallCount` 3, `minUniqueQueries` 2), **rehydrated from the live source file** immediately before write, and marked idempotently so re-runs never duplicate. Machine state lives in a hidden directory (`memory/.dreams/`); human-readable output lives in a diary file (`DREAMS.md`) that is *never* eligible for promotion — the pipeline must not eat its own output. A reversible **grounded backfill** lane lets you replay historical daily notes through the ranker without polluting live recall state.

This pays off above ~100 memory entries, when the per-write decision described in [memory.md](./memory.md#agent-written-memory-writing) is too small to make well in the moment. Below that, write-on-demand plus the background extractor is enough.

---

## Recommendation

### Where the pipeline sits

The write-on-demand model ([memory.md](./memory.md)) makes each save decision at the moment of observation: the agent (or the post-turn extractor) sees something worth keeping and writes a topic file. That decision is *local* — it can't see that the same fact has surfaced eleven times across three weeks under six different queries. Consolidation is the *global* complement: it watches how memory is actually **recalled** over time and promotes what recall behavior proves durable.

Inputs, in decreasing signal quality:

1. **Recall traces** — every `memory_search` / `memory_get` hit, recorded at read time (see below). The primary signal: what the agent actually reached for.
2. **Daily memory files** (`memory/YYYY-MM-DD.md`) — short-term append-only notes, the staging tier below topic files.
3. **Redacted session transcripts** — optional; sensitive content must be redacted *before* ingestion, not after.

Output: **promotions into `MEMORY.md` only.** No other durable write target exists. Everything else the pipeline produces is either machine state or human-readable reporting.

Consolidation is **not** in-session compaction. Compaction condenses one conversation's history and belongs to the [Context Engine](../context-engine/); consolidation moves cross-session evidence into durable memory on a schedule, with no conversation in flight. The two meet only at the [memory-flush handshake](./README.md) (pre-compaction flush is its own sub-topic).

### The recall store is the substrate

None of this works without read-time instrumentation. Every memory search/get records a compact recall entry into a machine-state store (`memory/.dreams/short-term-recall.json`):

- **Key** — stable identity: source path + line range (plus an optional content-claim hash for dedupe across moves).
- **Snippet** — the recalled text, for later rehydration comparison.
- **Query hashes** — hashes of the queries that surfaced it, capped (~32) so one hot entry can't grow unboundedly.
- **Recall days** — the distinct days on which it was recalled, capped (~16), feeding the consolidation signal.
- **Scores** — per-recall retrieval quality (avg and max retained).
- **Timestamps** — first/last recalled, for recency decay.

Record on the read path, cheaply and synchronously; *analyze* only in the background sweep. If recording ever becomes expensive enough to notice, cap harder rather than moving analysis inline.

### Phase model

One sweep, three phases, strictly ordered: **light → REM → deep**.

| Phase | Purpose | Durable write |
| ----- | ------- | ------------- |
| **light** | Ingest recent daily signals, recall traces, redacted transcripts; dedupe; stage candidate lines | No |
| **REM** | Extract themes and reflective patterns from recent traces; record reinforcement signals | No |
| **deep** | Rank staged candidates against threshold gates; promote top scorers into `MEMORY.md` | **Yes — the only one** |

Two design rules matter more than the phase names:

1. **Exactly one phase writes durably.** Light and REM produce staging artifacts and reinforcement signals consumed by deep ranking. Concentrating the durable write in one place gives you a single point for locking, idempotence, rehydration, and rollback.
2. **Phases are internal implementation details, not user-facing modes.** Users configure `enabled` and `frequency` (cron, default `0 3 * * *`, timezone-aware); the phase policy, thresholds, and storage behavior stay internal. Expose *observability* into phases (status, counts, next-run), not *configuration* of them.

The sweep runs from **one auto-managed cron job** the memory subsystem owns. Don't make users wire their own scheduler entry; don't allow multiple overlapping sweep jobs.

**Default off.** A pipeline that autonomously writes durable memory — content that lands in every future system prompt — should be opt-in. Provide a status/on/off slash command (`/dreaming status|on|off`) so enabling is one message, not a config-file edit.

### Ranking: weighted signals plus phase reinforcement

Deep-phase score is a weighted sum of six base signals:

| Signal | Weight | What it measures |
| ------ | ------ | ---------------- |
| Relevance | 0.30 | Average retrieval quality across recalls |
| Frequency | 0.24 | How many short-term signals the entry accumulated |
| Query diversity | 0.15 | Distinct query contexts that surfaced it |
| Recency | 0.15 | Time-decayed freshness (half-life ~14 days) |
| Consolidation | 0.10 | Multi-day recurrence strength |
| Conceptual richness | 0.06 | Concept-tag density from snippet/path |

Plus a small **phase-reinforcement boost**: entries that light/REM phases repeatedly staged or reflected on get a recency-decayed bump (capped — e.g. ≤0.06 from light, ≤0.09 from REM, same ~14-day half-life), read from a separate phase-signals file. The rationale for the caps: repeated dreaming revisits should be able to *tip* a borderline candidate over the gate without requiring fresh organic recall traffic — but reinforcement alone must never carry a candidate that organic signals don't support.

The specific weights are defensible defaults, not magic; what's load-bearing is the *shape* — relevance and frequency dominate, diversity/recency are secondary, no single signal exceeds ~⅓ of the total.

### Threshold gates: a spike is not a memory

Weighted score alone is gameable by one noisy burst (a single session that recalls the same entry twelve times). Require **all** of:

- `minScore` — composite floor (default 0.75).
- `minRecallCount` — minimum total recalls (default 3).
- `minUniqueQueries` — minimum distinct query contexts (default 2).

The second and third gates are what make the first honest: an entry must have been reached for *repeatedly*, from *different directions*, before it earns a durable slot.

**Make promotion explainable.** Provide a `memory promote-explain <query>` command that shows, for a matching candidate, each signal component, the boost, the composite score, and which gate(s) it fails. Threshold tuning without explain output is guesswork; with it, it's a five-minute exercise.

### Write-time integrity (deep phase)

The durable write needs four guards:

**Rehydrate before write.** Staged candidates hold a snapshot of the snippet as it looked at staging time. Before committing, re-read the snippet from the live daily file at the recorded path/lines. If the source was deleted or edited, **skip** the candidate. This single rule stops the pipeline from promoting stale or user-retracted notes — the staging store is evidence, never the source of truth.

**Contamination guard.** The pipeline generates text (diary entries, phase reports, subagent prompts). None of it may re-enter the candidate pool. Filter recognizable pipeline-generated content at both staging and write time (match on the diary-prompt pattern and report-file paths). Without this, the pipeline converges on promoting summaries of its own summaries.

**Idempotent promotion markers.** Each promoted entry appends a hidden marker comment carrying the candidate's stable key (e.g. `<!-- memory-promotion:<key> -->`) next to the `MEMORY.md` line. Re-runs check existing markers and skip already-promoted candidates. This makes the sweep safely re-runnable after a crash or manual `promote --apply`.

**Cross-process locking.** The sweep, an interactive session's recall recording, and a manual CLI promote can all touch the store concurrently. Use a sidecar lock file with a bounded wait (~10 s), stale-lock takeover (~60 s), and short retry delay — plus an in-process lock map for same-process reentrancy. Same discipline as memory-file writes in [memory.md](./memory.md#agent-written-memory-writing).

### Machine state vs. human artifacts

Keep the two strictly separate:

- **`memory/.dreams/`** — recall store, phase signals, ingestion checkpoints, locks. Machine-owned; never loaded into any prompt; safe to delete (you lose evidence, not memories).
- **`MEMORY.md`** — promotions only. The one durable target.
- **`DREAMS.md`** — an optional human-readable **diary**: after each phase accumulates enough material, a best-effort background subagent turn writes a short narrative entry. Optionally, per-phase report files under `memory/dreaming/<phase>/YYYY-MM-DD.md`.

The diary exists for *review* — it's what a user reads to audit what consolidation is doing and why. It is explicitly **not a promotion source** (see contamination guard). Surfacing it in an operator UI (a "Dreams" view with phase status, staged/promoted counts, next-run time, and a diary reader) is the difference between a pipeline users trust and one they disable after the first surprise.

### Grounded backfill: reversible experimentation

When a user enables consolidation after months of accumulated daily notes, there's no recall history to rank against. Provide a **grounded backfill lane** that replays historical `memory/YYYY-MM-DD.md` files through the pipeline — with every step reversible:

1. **Preview** — render grounded diary output from historical notes without writing anything.
2. **Write diary** — commit reversible, specially-tagged diary entries into `DREAMS.md`.
3. **Stage candidates** — optionally stage grounded durable candidates into the *same* evidence store the normal deep phase uses (tagged as grounded so the UI can show which staged entries came from replay vs. live recall).
4. **Rollback** — `--rollback` removes backfill diary artifacts, `--rollback-short-term` removes staged grounded candidates — both without touching ordinary diary entries or live recall state.

The tagging matters: because grounded entries stay distinguishable end-to-end, you can experiment with promotion thresholds against historical data, inspect the results, and clear *only* the experiment.

### Operator surface

Minimum viable controls:

- **Slash command** — `/dreaming status|on|off`.
- **CLI** — `memory promote` (preview) / `memory promote --apply` / `--limit N`; `memory promote-explain <query>`; `memory status --deep`; a backfill preview/apply/rollback set.
- **Status UI** (if the harness has one) — enabled state, per-phase status, staged/grounded/promoted-today counts, next scheduled run, diary reader.

Manual `promote` should use deep-phase thresholds by default, overridable by flag — one ranking implementation, two entry points.

---

## Alternatives

**No pipeline (write-on-demand only).** The main [memory.md](./memory.md) recommendation: typed topic files, background extractor, index recall. Right answer below ~100 entries — consolidation infrastructure isn't free, and small memory volumes don't produce enough recall signal to rank on. Add dreaming only when memory demonstrably accumulates noise or misses recurring themes.

**End-of-session distillation.** An `on_session_end(messages)` hook (see [memory.md § Lifecycle hooks](./memory.md#lifecycle-hooks-advanced)) that distills each session into durable notes as it closes. Simpler — no cron, no recall store — but the unit of evidence is one session, so it can't see cross-session recurrence, which is precisely the signal that distinguishes durable knowledge from session residue. Reasonable middle tier; complementary rather than exclusive.

**Periodic LLM rewrite.** On a schedule, hand `MEMORY.md` plus recent notes to a model with "consolidate this." Cheapest to build, and hits every anti-pattern below at once: no provenance, non-deterministic, can silently delete good entries, nothing is explainable or reversible. Acceptable only as a user-invoked manual command whose diff the user reviews before applying — never autonomous.

**Embedding-cluster consolidation.** Cluster memory entries by embedding similarity, merge clusters. Attacks redundancy (near-duplicate entries) rather than durability (what deserves promotion), needs embedding infrastructure, and merge-writes are the riskiest kind (destructive edits of existing entries vs. dreaming's append-only promotions). Consider it a *dedupe* pass layered on top, not a replacement.

---

## Anti-patterns

- **More than one phase writing durably.** The moment light or REM can touch `MEMORY.md`, you have three write paths to lock, three to make idempotent, three to roll back. Concentrate the durable write.

- **Promoting the pipeline's own output.** Diary entries and phase reports that re-enter the candidate pool produce a self-reinforcing loop: the pipeline promotes summaries of its summaries, each generation less grounded. Filter pipeline-generated content at staging *and* at write time.

- **Promoting from the staged snapshot.** The evidence store is months of accumulated state; the user may have deleted or corrected the source note since staging. Skipping rehydration means confidently promoting retracted information. Always re-read from the live file; skip on mismatch.

- **Score-only gating.** A composite score without count and diversity floors lets one noisy session push junk into durable memory. `minRecallCount` and `minUniqueQueries` are what make the score floor meaningful.

- **Consolidation on by default.** An autonomous process that writes into every future system prompt needs explicit consent. Ship it off; make enabling trivial.

- **Irreversible backfill.** Replaying historical notes without tagged, rollback-able artifacts means one threshold experiment permanently pollutes both the diary and the evidence store. Every backfill artifact must be distinguishable and removable.

- **Machine state in human files** (or vice versa). Ingestion checkpoints in `DREAMS.md`, or diary prose in the recall store, breaks both audiences: the user can't review, the pipeline can't parse. Hidden directory for machine state; markdown for humans; `MEMORY.md` for exactly one thing.

- **Unlocked concurrent access.** A 3 a.m. sweep racing an active session's recall recording corrupts the store silently — the failure shows up weeks later as nonsense rankings. Sidecar lock with stale takeover, same as every other memory write path.

- **Exposing phase internals as configuration.** Users who can configure per-phase thresholds will, and every bug report becomes unreproducible. Expose `enabled` + cadence + explain/status tooling; keep phase policy internal until real demand proves otherwise.

- **No explain path.** If a user can't ask "why was/wasn't this promoted?", their only recourse when consolidation misbehaves is disabling it. `promote-explain` is cheap insurance for the whole feature's adoption.

---
