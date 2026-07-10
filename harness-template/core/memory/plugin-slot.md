# Memory as an exclusive plugin slot with parallel knowledge layers

## Implementation (S1)

The exclusive capability record and registry are implemented: `MemoryCapability` (four optional slots), `MemoryCapabilityRegistry` (one active backend; registration replaces the default `builtin-file` file-store backend), and `FileStoreMemoryBackend` as the default owner of recall, snapshot, extraction, active memory, search, and dreaming. `DefaultMemoryService` orchestrates project instructions, flush trigger/dedupe/write-guard, and delegates runtime work to the active capability. Corpus supplements, prompt supplements, plugin manifest auto-loading, and full `publicArtifacts` consumers (wiki bridge) are deferred to follow-on work.

---

## TL;DR

When a harness supports multiple memory backends (built-in SQLite, local sidecar indexes, hosted memory services), don't federate them — make memory an **exclusive plugin slot**: exactly one active backend registers a **capability record** with four optional slots (`promptBuilder`, `flushPlanResolver`, `runtime`, `publicArtifacts`) and owns recall, promotion, flush policy, and consolidation outright. Around that exclusive slot, provide two **non-exclusive supplement surfaces**: *corpus supplements* (parallel searchable corpora reachable through the shared `memory_search` via corpus selection) and *prompt supplements* (extra prompt sections, sorted deterministically). This is what lets a provenance-rich **wiki layer** — compiled pages, structured claims with evidence, contradiction and freshness tracking, dashboards — sit *beside* the active backend without competing with it. The wiki reads the backend's exports through a **public-artifacts seam**, never private internals; agents consume it through compiled machine digests, never by scraping markdown.

---

## Recommendation

### Why exclusive

Two memory backends active at once produce conflicting recall (both answer every search, with different notions of relevance), duplicated promotion (both decide what's durable), and a bloated tool schema (two sets of memory tools the model must choose between). There is no principled merge: relevance scores from different engines aren't comparable, and promotion decisions can't be shared. So don't merge — pick. One active backend owns the entire read/write lifecycle; everything else in the memory ecosystem is either a *supplement* to that backend or a *consumer* of its exports.

Enforcement: the registration API holds a single capability record. The reference behavior on double-registration is last-write-wins; the better behavior is **reject the second registration with a clear error** naming the already-active plugin (see [memory.md § Lifecycle hooks](./memory.md#lifecycle-hooks-advanced) — "allow the always-on built-in provider plus at most one external provider"). Either way, exactly one record is live at a time, and it carries the owning `pluginId` so diagnostics can say *which* plugin owns memory.

### The capability record

The active backend registers one record with four optional slots:

```
MemoryCapability {
  promptBuilder?       // builds the memory section of the system prompt
  flushPlanResolver?   // pre-compaction flush policy (thresholds, prompts, target path)
  runtime?             // search-manager factory + backend-config resolution + shutdown
  publicArtifacts?     // lists exported artifacts for external consumers
}
```

- **`promptBuilder(availableTools, citationsMode) → string[]`** — the backend writes its own prompt section (how to use its tools, what its file layout means). Parameterized on the *available* tool set so the section never documents a tool the agent can't call.
- **`flushPlanResolver`** — the pre-compaction flush contract from [memory-aware-compaction.md](./memory-aware-compaction.md): backend owns flush policy, runtime owns the trigger. A backend with no flush concept returns null.
- **`runtime`** — `getMemorySearchManager({agentId, purpose})` (per-agent managers; a `purpose` discriminator like `default` vs `status` lets health checks get a manager without warming the full index), `resolveMemoryBackendConfig` (which storage engine, per agent), and `closeAllMemorySearchManagers()` for clean shutdown.
- **`publicArtifacts`** — see below; this is the seam that makes parallel layers possible.

A unified single-registration record beats N independent `registerX()` calls: the capability arrives and departs atomically with the plugin, and there's no half-registered state where a backend's flush plan is live but its runtime isn't. (Keep deprecated per-function registration paths only as a migration shim, marked loudly.)

The slot pattern itself — capability-typed record over abstract base class, manifest-first validation — is the general extensibility recommendation; see [extensibility](../../cross-cutting/extensibility/README.md). Memory is simply the layer where *exclusivity* matters most.

### The two non-exclusive surfaces

Beside the exclusive slot, two registration surfaces accept **many** entrants:

**Corpus supplements** — `{search(query), get(lookup)}` pairs, keyed by `pluginId` (re-registration by the same plugin replaces its own entry). These plug additional searchable corpora into the *shared* memory tools: `memory_search corpus=all` spans the active backend plus every supplement in one pass, while `corpus=<name>` targets one. Supplement results carry **provenance fields** — corpus name, provenance label, source type/path, citation, updated-at, line ranges — so recall output can say *where* a hit came from and the [citation discipline](./memory.md) survives federated search.

**Prompt supplements** — additional prompt-section builders from non-active plugins (e.g., the wiki layer's compact digest). Compose them **sorted by `pluginId`**, not by registration order: plugin load order varies run to run, and an order-unstable prompt section defeats the prefix cache and makes prompt diffs noisy.

The rule of thumb: the exclusive slot answers "who owns memory?"; the supplement surfaces answer "who else may be *read* through memory's tools?" Supplements never write, never promote, never flush.

### The public-artifacts seam

The capability record's `publicArtifacts` provider lists what the backend deliberately exports:

```
Artifact { kind, workspaceDir, relativePath, absolutePath, agentIds[], contentType }
```

— e.g. the memory index file, daily notes, consolidation reports. This is the **only** supported way for another plugin to read the active backend's data. The alternative — a parallel layer reaching into the backend's private directories — couples it to one backend's internal layout and breaks the moment the user swaps backends. With the seam, a consumer asks "what do you export?" and works identically over any backend that answers; a backend that exports nothing simply yields zero artifacts (surface that in a doctor/status command rather than failing silently).

### The parallel knowledge layer (memory wiki)

The flagship consumer of this architecture is a **wiki layer**: a compiled knowledge vault that sits beside the active backend and makes durable knowledge behave like a *maintained reference* instead of a pile of notes. Division of labor:

| Layer | Owns |
| ----- | ---- |
| Active memory backend | Recall, semantic search, promotion, flush policy, [consolidation](./consolidation.md), memory runtime |
| Wiki layer | Compiled pages, structured claims + evidence, contradiction/freshness tracking, dashboards, wiki-native tools |

What makes the wiki a *belief layer* rather than more notes:

- **Structured claims in frontmatter** — each claim has `id`, `text`, `status`, `confidence`, `evidence[]` (source id, path, lines, weight, note), `updatedAt`. Claims can be tracked, scored, contested, and resolved back to sources — none of which freeform markdown supports.
- **Deterministic vault layout** — `sources/` (imported raw material), `entities/` (durable things/people/systems), `concepts/` (ideas and patterns), `syntheses/` (maintained rollups), `reports/` (generated dashboards). Generated content lives inside managed blocks; **human note blocks are preserved** across recompiles.
- **A compile pipeline with machine-facing output** — compilation normalizes pages into stable digests (`agent-digest.json`, `claims.jsonl`). Agents and runtime code consume the digests, never scrape the markdown; the digests also power first-pass search, claim-id → owning-page lookup, and dashboard generation.
- **Health dashboards** — generated reports for open questions, contradiction clusters, low-confidence claims, claim health, and stale pages. This is memory *quality* made visible — the operator-facing answer to "is my agent's knowledge rotting?"
- **Narrow tools** — `wiki_status` / `wiki_search` / `wiki_get` / `wiki_apply` / `wiki_lint`. The write tool (`wiki_apply`) accepts only **narrow synthesis/metadata mutations**, not freeform page surgery: an agent may add a synthesis or update claim metadata, but restructuring a page stays a human (or compile-pipeline) act. `wiki_lint` checks structure, provenance gaps, contradictions, and open questions.
- **Ranking that uses belief state** — contested, stale, and fresh claims influence search ranking, and provenance labels survive into results.

**Vault modes.** Offer three: `isolated` (own vault, own sources — no dependency on the active backend), `bridge` (index the backend's public artifacts and event logs *through the public seam*: exported artifacts, consolidation reports, daily notes, memory root files), and an explicitly-experimental `unsafe-local` escape hatch for arbitrary local paths — named to signal the trust boundary it crosses. Default to `isolated`; `bridge` is the power pattern for "recall backend + compiled knowledge layer" hybrids.

**Prompt integration is opt-in.** The wiki can append a compact digest snapshot (top pages, top claims, contradiction/question counts) as a prompt supplement — ship it **off** by default. It changes prompt shape for every turn, and most sessions don't need standing wiki context; the agent can `wiki_search` when it does.

**Routing guidance for the model** (one line each in the prompt): use `memory_search` for one broad recall pass; use `wiki_search`/`wiki_get` when provenance and belief structure matter; use `corpus=all` to span both.

### Operator surface

A backend-management CLI (`memory status --deep` to inspect the active backend and index health) plus a wiki CLI (`status` / `doctor` / `init` / `ingest` / `compile` / `lint` / `search` / `get` / `apply` / bridge import). The `doctor` command matters most: when bridge mode indexes zero artifacts, the answer is usually "the active backend doesn't export public artifacts," and doctor should say so explicitly rather than leaving an empty wiki to be discovered.

---

## Alternatives

**No slot — one built-in memory.** The [memory.md](./memory.md) baseline. If your harness has one memory design and no demand for alternatives, a plugin slot is speculative generality; the file conventions and taxonomy matter more than swappability. Adopt the slot when the *second* real backend shows up, not before.

**Lifecycle-hook provider contract.** The `initialize / prefetch / sync_turn / on_pre_compress / on_session_end` hook interface ([memory.md § Lifecycle hooks](./memory.md#lifecycle-hooks-advanced)) with the always-on built-in plus at most one external provider. Slightly different emphasis — hooks are turn-lifecycle-shaped, the capability record is service-shaped — but the same exclusivity principle. A reasonable convergence target is hooks *inside* the capability record's `runtime`.

**Memory as filesystem middleware.** No memory-specific plugin surface at all: the agent edits a `/memories/` directory through its ordinary file tools, and persistence is a backend abstraction of the filesystem layer. Cheapest to build in harnesses that already have pluggable filesystems, and the "memory writes are ordinary file diffs" legibility is real. But there's no place to hang search managers, flush plans, or supplements — retrieval stays grep-grade, and everything this page describes has nowhere to live.

**Federated multi-backend query.** Let several backends register and merge their recall behind one query API. Attractive on paper (each backend contributes its strength), but relevance scores across engines aren't comparable, dedupe across stores is heuristic at best, and write/promotion ownership becomes ambiguous. The corpus-supplement surface is the disciplined version of this idea: federation for *reads*, exclusivity for *ownership*.

---

## Anti-patterns

- **Two active memory backends.** Conflicting recall, duplicate promotion, doubled tool schema. If a user enables two, fail loudly at load with the name of the incumbent — silent last-write-wins means the user's configured backend silently isn't the one running.

- **A parallel layer that also promotes.** If the wiki (or any supplement) starts writing durable memory or running its own consolidation, ownership fragments and the same fact gets promoted twice with different wording. Supplements are read-side. The wiki *compiles*; the backend *remembers*.

- **Bridge-by-trespass.** A consumer that reads the active backend's private files directly works until the user swaps backends, then breaks — or worse, keeps reading a stale directory the new backend doesn't use. Public-artifacts seam only; zero exports is a diagnosable condition, not permission to go around.

- **Freeform page-editing as the wiki write tool.** Give an agent "edit any wiki page" and compiled structure degrades into prose within a week. The write tool accepts narrow, schema-shaped mutations (`wiki_apply`); structural change belongs to the compile pipeline and humans.

- **Machine consumers scraping vault markdown.** Parsing wiki pages from disk couples every consumer to the page format and breaks on the first template tweak. Compile to stable digests; consumers read digests.

- **Recompiles that clobber human notes.** The vault is also a human notebook. Managed blocks for generated content, preserved blocks for human notes — a compile that rewrites whole files destroys the operator's trust along with their annotations.

- **Registration-order-dependent prompt supplements.** Plugin load order is not stable across runs; supplement order must be (sort by plugin id). An unstable prompt section is a prefix-cache killer and makes A/B comparisons of prompt behavior meaningless.

- **Digest-in-prompt on by default.** Standing wiki context in every turn taxes every session for a feature most turns don't use. Opt-in, compact, high-signal.

- **Piecemeal capability registration.** Four independent `registerX()` calls create half-registered states (flush plan live, runtime missing) that surface as baffling partial behavior. One record, registered and torn down atomically.

---
