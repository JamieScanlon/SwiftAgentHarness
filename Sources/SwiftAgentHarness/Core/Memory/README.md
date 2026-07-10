# Memory

Cross-session durable knowledge: project-instruction files (`AGENTS.md` / `CLAUDE.md`), agent-written memory (`MEMORY.md` index + topic files + daily staging notes), recall, extraction, and consolidation.

Normative spec: harness-template `core/memory/memory.md` and `core/memory/README.md`.

## Layout (capture vs curate)

| Artifact | Role |
|----------|------|
| `memory/YYYY-MM-DD.md` | **Staging** — capture-cheap daily notes (no taxonomy frontmatter); light phase stages from these |
| Typed topic `*.md` | **Curated** — four-type frontmatter; always-on recall via manifest |
| `MEMORY.md` | **Index only** — one-line links to curated topics; deep promotion target |
| `memory/.dreams/` | Machine state (recall store, last-deep marker) |
| `DREAMS.md` | Optional human diary (not required for C3) |

Deep promotion requires all three threshold gates (defaults: `dreamingMinScore` ≥ 0.75, `dreamingMinRecallCount` ≥ 2, `dreamingMinUniqueQueries` ≥ 2). Staged dailies must accumulate enough recall traces before they can promote.

## Boundary

| Consumer | Uses Memory for |
|----------|-----------------|
| **Context Engine** | Frozen snapshot system prompt blocks at `assemble` |
| **Agent Runtime** | `onTurnEnded` → background extraction; active-memory pre-reply |
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
| `DreamingConsolidationScheduler.swift` | Light / REM / deep consolidation over dailies + recall boosts |
| `DreamingControlStore.swift` | On/off gate for dreaming (`/dreaming`); default on |
| `MemoryDreamingBridge.swift` | Enumerates project memory dirs and runs due sweeps |
| `MemoryDreamingCronInstaller.swift` | Permanent system cron `dream` consuming `dreamingCron` |
| `MemoryDreamingDeliver.swift` | Cron deliver short-circuit (no LLM turn for dream fires) |
| `MemorySessionSnapshot.swift` | Frozen per-session snapshot |
| `MemoryRecallSelector.swift` | Turn recall (LLM + heuristic fallback) |
| `BackgroundMemoryExtractor.swift` | Post-turn extraction subagent |
| `MemoryProviderRegistry.swift` | Built-in + single external provider slot |

Operator surface: `/dreaming status|on|off`. Triggers installs a permanent `dream` cron (`0 3 * * *` by default) that calls the bridge directly.

## Related

- [`../ContextEngine/README.md`](../ContextEngine/README.md) — consumes memory injection snapshots
- [`../ToolSystem/README.md`](../ToolSystem/README.md) — file tool dispatch and write gates
