# Memory

Cross-session durable knowledge: project-instruction files (`AGENTS.md` / `CLAUDE.md`), agent-written memory (`MEMORY.md` index + topic files + daily staging notes), recall, extraction, and consolidation.

Normative spec: harness-template `core/memory/memory.md`, `core/memory/pre-reply-recall.md`, `core/memory/memory-aware-compaction.md`, and `core/memory/README.md`.

Pre-compaction flush is default-on on both Memory and Context Engine gates; soft-threshold flush-only runs with headroom before hard compaction (see `memory-aware-compaction.md`). Flush promotes to **curated typed topic files only** (append-only for existing topics and `MEMORY.md` index lines); daily staging is out of scope for flush (extraction/dreaming still use dailies). Optional `memory.preCompactionFlushSystemPromptPath` customizes flush task guidance; three harness-enforced safety hints (target / append-only / read-only scope) are always re-appended, with `PreCompactionFlushWriteGuard` at the tool layer.

On hard compaction, after optional flush and before the summarizer, the **active** memory backend runs `onPreCompress(messages:)`; the return string is included in the compaction summarizer handoff prompt (see `memory-aware-compaction.md`). Flush dedupe (per-message ID coverage + middle fingerprint) prevents re-flushing overlapping middle segments within a compaction cycle. Plugin-visible compaction hooks (`before_compaction` / `after_compaction`) are deferred to the extensibility assessment (see `memory-aware-compaction.md` § Observability (deferred)).

**Exclusive plugin slot (S1).** One active `MemoryCapability` owns recall, promotion, flush policy, and runtime hooks. `DefaultMemoryService` is an orchestrator: project-instruction loading, flush trigger/dedupe/write-guard, and write tracking stay in the service; everything else delegates to the active capability's slots. Default registration is `builtin-file` (`FileStoreMemoryBackend`). `registerActiveMemoryCapability(_:)` or `registerExternalMemoryProvider(id:provider:)` **replaces** the active backend (legacy `MemoryProviding` adapter is test/transition-only — hook-only, no recall ownership). Pre-compaction flush **policy** (prompts, write guard, entry-ID selection) lives in `MemoryFlushPlanResolving`; flush **execution** (spawn, timeout, write-guard application) stays in the service.

**Real capability seams (S2).** Slots are backend-resolved, not service-hardcoded: `MemoryFlushPlan` carries write-guard policy and entry-ID selection via the active `flushPlanResolver`; memory prompt sections come only from `promptBuilder` (project instructions remain a parallel service layer); `activePublicArtifacts(conversationID:)` exposes the active backend's `publicArtifacts` provider. Operator surface: `memory status [--deep]` prints active plugin ID and exported artifact paths.

## Layout (capture vs curate)

| Artifact | Role |
|----------|------|
| `memory/YYYY-MM-DD.md` | **Staging** — capture-cheap daily notes (no taxonomy frontmatter); light phase stages from these |
| Typed topic `*.md` | **Curated** — four-type frontmatter; always-on recall via manifest |
| `MEMORY.md` | **Index only** — one-line links to curated topics; deep promotion target |
| `memory/.dreams/` | Machine state (recall store, promotions ledger, last-deep marker, `last-sweep.json`) — never a promotion candidate |
| `DREAMS.md` | Human-readable dreaming diary — appended each sweep; excluded from candidates |

Deep promotion requires all three threshold gates (defaults: `dreamingMinScore` ≥ 0.75, `dreamingMinRecallCount` ≥ 2, `dreamingMinUniqueQueries` ≥ 2). Staged dailies must accumulate enough recall traces before they can promote.

Active memory (pre-reply recall) **ships on**: `activeMemoryEnabled` and both standing/situational lane flags default `true`. Set PromptConfig `memory.activeMemoryEnabled: false` (or a per-lane `*Enabled: false`) to disable. Soft pause without redeploy: `/active-memory off` (session) or `/active-memory off --global`. Coding sessions are `chatType: direct`, so the direct-chat gate does not act as an off-switch; group/channel still skip unless the host sets a non-direct type.

Operator observability: `/verbose on` and `/trace on` append post-reply `Active Memory: status=…` / `Active Memory Debug: …` lines; `activeMemoryLogging` (default true) emits `active-memory: start|done` debug logs. Per-conversation recall cache is capped at `activeMemoryRecallCacheMaxEntries` (default 1000) with LRU eviction preferring situational keys.

Active-memory **model** is pool-native: optional `memory.activeMemoryModelRef` pin → `ModelQuery` with `preferredUseClass: memory-recall` + `.completion`/`.tools` (provider trust tier matches the session by default; set `activeMemoryAllowCrossProviderTrust: true` to opt out) → parent session model if tools-capable → skip. No hardcoded Ollama-only default on the spawn path.

Autonomous dreaming **ships off**: set PromptConfig `memory.dreamingEnabled: true` to opt in. After opt-in, `/dreaming on|off` is a soft runtime toggle (control store; missing file defaults on). Both config and control must be on for bridge sweeps; cron install is skipped (and any existing `dream` task removed) when `dreamingEnabled` is false.

Before writing, deep **re-reads the live daily**, skips if the staged snippet is gone, then derives topic title / description / body / index hook from a fresh `richestSnippet` of that live body (not the light-phase snapshot alone). A contamination denylist blocks `MEMORY.md`, `DREAMS.md`, and `.dreams/*` machine artifacts from staging or promotion.

Each non-rollback sweep writes `.dreams/last-sweep.json` (phase outcomes + reject reasons) and appends a section to `DREAMS.md`. Use `/dreaming explain` or `memory dreaming explain` to tune thresholds; `/dreaming status` / `memory dreaming status` show thresholds and last-run summary.

Deep durable writes, rollback, and memory-directory `write_file` / `edit_file` share the sidecar `.memory.lock` (sweep-scoped hold for promote + reviewability). Nested store helpers use assuming-locked APIs because `flock` is not reentrant.

Promotions are tagged (`origin: dreaming-deep`) and ledgered under `.dreams/promotions.jsonl`. `memory rem-backfill --rollback` (alias `--rollback-short-term`) reverses the last run’s created topics and `MEMORY.md` lines without touching dailies, recall traces, or the diary/report.

## Boundary

| Consumer | Uses Memory for |
|----------|-----------------|
| **Context Engine** | Frozen snapshot system prompt blocks at `assemble` |
| **Agent Runtime** | `onTurnEnded` → background extraction; active-memory pre-reply (`NONE` → no injection; spawn `toolsAllow` + `memory-active-recall` mode profile gate tools at the gateway; note budget default 220 chars; situational `queryMode` default `recent` + `promptStyle` `balanced` with capped prior turns for follow-up pronouns; ignore/strip prior `<memory-context>` to prevent feedback loops) |
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
| `ActiveMemoryQueryMode.swift` | Situational `queryMode` / `promptStyle` enums |
| `ActiveMemorySituationalQueryBuilder.swift` | Builds capped recent/full situational query payloads from transcript |
| `ActiveMemoryControlStore.swift` | Global soft on/off (`/active-memory … --global`) |
| `ActiveMemorySessionFlags.swift` | Session metadata keys for enable / verbose / trace |
| `ActiveMemoryTurnDiagnostics.swift` | Per-turn status line + debug summary payload |
| `ActiveMemoryRecallCache.swift` | Per-conversation standing/situational cache (TTL + max-entry LRU) |
| `MemorySessionSnapshot.swift` | Frozen per-session snapshot |
| `MemoryRecallSelector.swift` | Turn recall (LLM + heuristic fallback) |
| `BackgroundMemoryExtractor.swift` | Post-turn extraction subagent |
| `MemoryCapability.swift` | Exclusive capability record + slot protocols (`MemoryRuntime`, `MemoryPromptBuilding`, `MemoryFlushPlanResolving`, `MemoryPublicArtifactsProviding`) |
| `MemoryCapabilityRegistry.swift` | Single active capability; `register` rejects duplicate plugin ID; `replaceActive` for hot-swap |
| `FileStoreMemoryBackend.swift` | Default `builtin-file` backend (recall, snapshot, extraction, active memory, search, dreaming) |
| `MemoryProviderPreCompressNotes.swift` | Formats active-backend `onPreCompress` notes for compaction summarizer handoff |
| `PreCompactionFlushDedupeState.swift` | Per-cycle flush dedupe (message IDs + middle fingerprint) |

Operator surface: `/dreaming status|explain|on|off` (CLI: `memory dreaming status|explain`). Opt-in via PromptConfig `memory.dreamingEnabled`. Triggers installs a permanent `dream` cron (`0 3 * * *` by default) only when dreaming is enabled in config.

## Related

- [`../ContextEngine/README.md`](../ContextEngine/README.md) — consumes memory injection snapshots
- [`../ToolSystem/README.md`](../ToolSystem/README.md) — file tool dispatch and write gates
