# Memory

Cross-session durable knowledge: project-instruction files (`AGENTS.md` / `CLAUDE.md`), agent-written memory (`MEMORY.md` index + topic files + daily staging notes), recall, extraction, and consolidation.

Normative spec: harness-template `core/memory/memory.md`, `core/memory/pre-reply-recall.md`, and `core/memory/README.md`.

## Layout (capture vs curate)

| Artifact | Role |
|----------|------|
| `memory/YYYY-MM-DD.md` | **Staging** — capture-cheap daily notes (no taxonomy frontmatter); light phase stages from these |
| Typed topic `*.md` | **Curated** — four-type frontmatter; always-on recall via manifest |
| `MEMORY.md` | **Index only** — one-line links to curated topics; deep promotion target |
| `memory/.dreams/` | Machine state (recall store, promotions ledger, last-deep marker, `last-sweep.json`) — never a promotion candidate |
| `DREAMS.md` | Human-readable dreaming diary — appended each sweep; excluded from candidates |

Deep promotion requires all three threshold gates (defaults: `dreamingMinScore` ≥ 0.75, `dreamingMinRecallCount` ≥ 2, `dreamingMinUniqueQueries` ≥ 2). Staged dailies must accumulate enough recall traces before they can promote.

Autonomous dreaming **ships off**: set PromptConfig `memory.dreamingEnabled: true` to opt in. After opt-in, `/dreaming on|off` is a soft runtime toggle (control store; missing file defaults on). Both config and control must be on for bridge sweeps; cron install is skipped (and any existing `dream` task removed) when `dreamingEnabled` is false.

Before writing, deep **re-reads the live daily**, skips if the staged snippet is gone, then derives topic title / description / body / index hook from a fresh `richestSnippet` of that live body (not the light-phase snapshot alone). A contamination denylist blocks `MEMORY.md`, `DREAMS.md`, and `.dreams/*` machine artifacts from staging or promotion.

Each non-rollback sweep writes `.dreams/last-sweep.json` (phase outcomes + reject reasons) and appends a section to `DREAMS.md`. Use `/dreaming explain` or `memory dreaming explain` to tune thresholds; `/dreaming status` / `memory dreaming status` show thresholds and last-run summary.

Deep durable writes, rollback, and memory-directory `write_file` / `edit_file` share the sidecar `.memory.lock` (sweep-scoped hold for promote + reviewability). Nested store helpers use assuming-locked APIs because `flock` is not reentrant.

Promotions are tagged (`origin: dreaming-deep`) and ledgered under `.dreams/promotions.jsonl`. `memory rem-backfill --rollback` (alias `--rollback-short-term`) reverses the last run’s created topics and `MEMORY.md` lines without touching dailies, recall traces, or the diary/report.

## Boundary

| Consumer | Uses Memory for |
|----------|-----------------|
| **Context Engine** | Frozen snapshot system prompt blocks at `assemble` |
| **Agent Runtime** | `onTurnEnded` → background extraction; active-memory pre-reply (`NONE` → no injection; spawn `toolsAllow` + `memory-active-recall` mode profile gate tools at the gateway) |
| **Tool System** | Workspace file tools + memory write gates; `memory_search` / `memory_get` |
| **Sub-Agent Pool** | Forked extraction subagent |
| **Model Pool** | Cheap recall selector + active-memory model |

Memory does **not** write to the conversation store; it reads transcripts via read-side APIs for dreaming only.

## Modules

| File | Role |
|------|------|
| `MemoryContracts.swift` | Layer protocols and DTOs |
| `DefaultMemoryService.swift` | Top-level facade |
| `GitRootResolver.swift` | Canonical git root for memory dir keying |
| `ProjectInstructionDiscovery.swift` | Cwd-upward instruction file walk |
| `ProjectInstructionLoader.swift` | Layer ordering, truncation, framing |
| `ProjectInstructionContentScanner.swift` | Injection/exfil scan on load and write |
| `SubdirectoryHintTracker.swift` | Lazy subdirectory hints on tool results |
| `AgentMemoryPathResolver.swift` | Secure memory directory resolution |
| `AgentMemoryStore.swift` | `MEMORY.md` + topic CRUD + daily staging append/read |
| `DreamRecallStore.swift` | Append-only recall traces under `memory/.dreams/recalls.jsonl` |
| `DreamPromotionLedger.swift` | Tagged promotion JSONL + last-deep marker (`runID`, `sourceDailies`) |
| `DreamSweepReport.swift` | Last-sweep JSON + diary append + explain/status formatters |
| `DreamingContaminationGuard.swift` | Denylist for diary / index / `.dreams` artifacts |
| `DreamingConsolidationScheduler.swift` | Light / REM / deep consolidation over dailies + recall boosts |
| `DreamingControlStore.swift` | On/off gate for dreaming (`/dreaming`); default on |
| `MemoryDreamingBridge.swift` | Enumerates project memory dirs and runs due sweeps |
| `MemoryDreamingCronInstaller.swift` | Permanent system cron `dream` consuming `dreamingCron` |
| `MemoryDreamingDeliver.swift` | Cron deliver short-circuit (no LLM turn for dream fires) |
| `ActiveMemoryRecallOutput.swift` | NONE-contract parse (`noteOrNil`) for pre-reply lanes |
| `MemorySessionSnapshot.swift` | Frozen per-session snapshot |
| `MemoryRecallSelector.swift` | Turn recall (LLM + heuristic fallback) |
| `BackgroundMemoryExtractor.swift` | Post-turn extraction subagent |
| `MemoryProviderRegistry.swift` | Built-in + single external provider slot |

Operator surface: `/dreaming status|explain|on|off` (CLI: `memory dreaming status|explain`). Opt-in via PromptConfig `memory.dreamingEnabled`. Triggers installs a permanent `dream` cron (`0 3 * * *` by default) only when dreaming is enabled in config.

## Related

- [`../ContextEngine/README.md`](../ContextEngine/README.md) — consumes memory injection snapshots
- [`../ToolSystem/README.md`](../ToolSystem/README.md) — file tool dispatch and write gates
