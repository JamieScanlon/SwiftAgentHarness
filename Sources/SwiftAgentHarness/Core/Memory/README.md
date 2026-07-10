# Memory

Cross-session durable knowledge: project-instruction files (`AGENTS.md` / `CLAUDE.md`), agent-written memory (`MEMORY.md` index + topic files), recall, extraction, and consolidation.

Normative spec: harness-template `core/memory/memory.md` and `core/memory/README.md`.

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
| `AgentMemoryStore.swift` | `MEMORY.md` + topic file CRUD |
| `DreamRecallStore.swift` | Append-only recall traces under `memory/.dreams/recalls.jsonl` |
| `DreamingConsolidationScheduler.swift` | Light / REM / deep consolidation over the recall store |
| `MemorySessionSnapshot.swift` | Frozen per-session snapshot |
| `MemoryRecallSelector.swift` | Turn recall (LLM + heuristic fallback) |
| `BackgroundMemoryExtractor.swift` | Post-turn extraction subagent |
| `MemoryProviderRegistry.swift` | Built-in + single external provider slot |

## Related

- [`../ContextEngine/README.md`](../ContextEngine/README.md) — consumes memory injection snapshots
- [`../ToolSystem/README.md`](../ToolSystem/README.md) — file tool dispatch and write gates
