# Context Engine

This folder hosts the **model-facing context assembly** pipeline: turning the append-only transcript plus persisted checkpoints into the message array fed to the orchestrator / LLM. It aligns with the harness **Context Engine** concept (`project(rawEvents, derivedEvents, config)`): The harness keeps **`ModelConversation.messages`** as **raw** history and persists checkpoint artifacts on the derived journal in the conversation event log (see package `Documentation/CONVERSATION_EVENT_LOG.md`). Cross-link: **`Documentation/PROJECTION.md`** (harness **read** / UI **project** vs orchestrator assembly).

## Two projections (do not conflate)

| Projection | Purpose | Raw source | “Derived” overlays |
|------------|---------|------------|---------------------|
| **Model context** (`DefaultContextEngine`) | Orchestrator / LLM input each turn | `ModelConversation.messages` | Context compaction checkpoints (`ContextCompactionCheckpointPayload`), applied via `ContextCompactionInputBuilder` + `ContextCompactionTransformer` |
| **UI preview** (`ConversationProjection`; `ConversationEventProjector` in `ConversationEventSourcing` forwards to it) | Sidebar / streaming UI | Same raw messages | **`CachedConversationEvent`** kinds such as `turn_summary_event` — summaries and hides spans for display |

Same high-level idea (overlay derived state on raw); **different event kinds and consumers** on the shared derived journal (see `CONVERSATION_EVENT_LOG.md`). Optional future work is a harness-style physical split of raw vs derived stores; the UI path stays on the event-log projector documented there.

## Related types

- **`Compaction/`** — `ContextCompactionInputBuilder` (transform input + gating) and `ContextCompactionCheckpointSupport` (payload, validity, effective middle).
- **`ConversationCheckpoint`** — harness-shaped umbrella enum across persisted kinds (`context_compaction`, `memory_injection_snapshot`, `tool_result_trim`, `system_prompt_assembly`, `attachment_projection`).
- **`DerivedEventStore`** — append/read seam for derived checkpoint rows. **`RoutingDerivedEventStore`** appends **`derived_journal`** transcript rows and reads tails/events through **`TranscriptConversationJournalWriter`** + **`HarnessSessionPersistence`** (composition-root closure; post-install override-safe). Raw markers use **`ConversationEventLogService`** on the same harness. **`SwiftDataDerivedEventStore`** is a deprecated typealias for **`RoutingDerivedEventStore`** only.
- **`ContextEngine` lifecycle API** — canonical runtime contract (`bootstrap`, `ingest`, `ingestBatch`, `assemble`, `compact`, `afterTurn`, `prepareSubagentSpawn`, `onSubagentEnded`, `projectedContextBudget`) used by runtime/manual callers.
- **Sub-agent lifecycle hook artifacts** — `prepareSubagentSpawn` / `onSubagentEnded` return deterministic CE-owned handoff/continuation artifacts (`policyFingerprint`) plus optional durable checkpoint invalidation directives.
- **`ContextEngineSlotResolver`** — composition-root slot resolver (`default`, `noop`) used by `ServerConfig.contextEngineSlotID` to choose engine implementation while preserving default behavior.
- **`ContextAssemblyPipeline`** — single ingest → **`assemble`** / **`compact`** → **`applyContextAssemblyPersistence`** path used by **`ContextProjectionService`** (orchestrator + manual compaction entry points). Read-only model-context preview uses **`ingestAndOrchestratorAssemblePreview`** (`persistCompactionCheckpoint: false`, no applicator) via **`ContextProjectionService.projectModelContextPreview`**.
- **`ContextAssemblyPersistenceApplicator`** — CE post-**`assemble`** / **`compact`** persistence for compaction, memory injection, pre-flush, system prompt assembly, and attachment projection (**orchestrator** vs **manual** scopes). Does not cover **`tool_result_trim`** (see below).
- **`ContextAssemblyRuntimeFacade`** — **`ContextEngineAssembleRequest`** construction + projection-input load (compaction mutex acquired on **`ContextProjectionService`** via **`withCompactionCriticalSectionIfNeeded`** before pipeline calls).
- **`ContextCheckpointWriter`** — context-layer writer for all durable checkpoint kinds. **`ContextAssemblyPersistenceApplicator`** invokes it after CE **`assemble`** / **`compact`**. **`HarnessRuntimeSession.appendMessagesToConversation`** invokes **`persistToolResultTrimCheckpointIfNeeded`** separately when a tool result was transform-synthesized.
- **`CompactionConcurrencyCoordinator`** — per-conversation mutex so two compaction LLM runs cannot race (harness compaction lock). **`ContextProjectionService`** acquires on orchestrator and manual compaction paths and passes **`compactionLockAlreadyHeldByCaller`**; the same instance is also injected into **`DefaultContextEngine`** for paths that call CE directly.
- **`LatestValidConversationCheckpoint`** — harness **`latestValidCheckpoint(kind:)`** dispatch across all persisted harness checkpoint kinds; compaction-only callers use **`latestValidCompaction(...)`**.

## Runtime checkpoint producer contract

Current runtime producers (real execution paths, not test-only store append calls), owned by Context Engine seams and invoked by runtime/manager callers:

| Harness kind | Persisted event kind | Producer path |
|---|---|---|
| `context_compaction` | `context_compaction_checkpoint` | **`ContextAssemblyPersistenceApplicator`** (orchestrator **`ContextProjectionService.transformedContextMessages`** / manual **`ContextProjectionService.performManualCompaction`**) → `ConversationPersistenceStack.persistContextCompactionCheckpoint` |
| `memory_injection_snapshot` | `memory_injection_snapshot_checkpoint` | **`ContextAssemblyPersistenceApplicator`** (orchestrator + manual scopes), from CE memory snapshot / pre-flush specs |
| `tool_result_trim` | `tool_result_trim_checkpoint` | `HarnessRuntimeSession.appendMessagesToConversation` → `ContextCheckpointWriter.persistToolResultTrimCheckpointIfNeeded` when a tool result was synthesized by tool-result transform |
| `system_prompt_assembly` | `system_prompt_assembly_checkpoint` | **`ContextAssemblyPersistenceApplicator`** (orchestrator scope only) → `ContextCheckpointWriter.persistSystemPromptAssemblyCheckpointIfNeeded(spec:...)` |
| `attachment_projection` | `attachment_projection_checkpoint` | **`ContextAssemblyPersistenceApplicator`** (orchestrator scope only) → `ContextCheckpointWriter.persistAttachmentProjectionCheckpointIfNeeded(spec:...)` |
| Sub-agent hook invalidation directives | `checkpoint_invalidated` | **`HarnessRuntimeSession`** sub-agent spawn/end hooks apply CE-returned invalidation specs and publish checkpoint invalidation topic wires. |

Selection validity (`latestValidCheckpoint`) still enforces schema/fingerprint/frontier and invalidation floors per kind via `SuiteCheckpointSupport` + `LatestValidConversationCheckpoint`.

Pre-compaction memory flush uses the existing `memory_injection_snapshot` checkpoint kind: CE emits a pre-compaction flush snapshot spec before initial-phase compaction, and runtime persistence reuses the memory snapshot durability/validity contract (no additional checkpoint kind).

On the orchestrator path, memory injection + pre-flush rows persist only when **`assemble`** produced transform output (`result.transformOutput != nil` in **`ContextAssemblyPipeline`**).

Plugin-visible compaction hooks (`before_compaction` / `after_compaction`) are not emitted by CE today; defer to the extensibility assessment (see harness-template `core/memory/memory-aware-compaction.md` § Observability (deferred)).

## Pluggability seams

- **Context engine slot:** production composition resolves `ServerConfig.contextEngineSlotID` and injects either:
  - `default` -> `DefaultContextEngine` (existing behavior), or
  - `noop` -> `NoOpContextEngine` (passthrough/no-compaction reference slot).
- **Compaction provider slot:** production transformer construction supports an optional provider slot (`ContextCompactionConfiguration.optionalCompactionProviderSlot`) with deterministic fallback behavior (`optionalCompactionProviderFallbackToOllama`).

## Deterministic hygiene pipeline

- Compaction now resolves one typed deterministic hygiene policy at input-build time (`ContextCompactionPolicy.resolvedDeterministicHygienePolicy`).
- Transformer execution runs one staged pre-summarizer path: strategy shaping -> cache-aware pruning -> attachment/document/image hygiene -> optional tool-result pruning.
- Defaults preserve prior behavior (`tool-result pruning on`, attachment/document/image hygiene off), while config knobs make stage ownership explicit under Context Engine policy surfaces.
- Pre-compaction memory flush is **default-on** (`preCompactionMemoryFlushEnabled: true`) and dual-gated with Memory’s `preCompactionFlushEnabled`. Soft threshold (`softThresholdTokens`, default 8k) runs a flush-only assemble before the hard proactive trigger; hard path still flushes then summarizes. Spec: harness-template `core/memory/memory-aware-compaction.md`.
- Identifier-preservation policy is resolved via `ContextCompactionPolicy.resolvedIdentifierPreservationPolicy` and threaded into compaction prompt construction (`strict` / `custom` / `off`) to preserve opaque IDs in summaries.

## Prompt + Attachment policy projection

- `ContextEngineProjectionPolicyInput` is the canonical CE-owned policy envelope for trust gating, attachment/document/image hygiene, attachment projection decision policy, and system-prompt assembly inputs.
- `DefaultContextEngine` now emits `ContextEngineProjectionArtifact` (resolved trust class + system-prompt metadata/fingerprint + attachment projection decisions) so manager/provider layers consume CE decisions instead of rebuilding policy ad hoc.
- Provider adapters accept CE-projected metadata via `contextEngineSystemPromptMetadata` (with backward-compatible fallback to `systemPromptMetadata`) and attachment decisions via `contextEngineAttachmentProjection`.

## Derived-event maintenance contract

- `DerivedArtifactContractMatrix` centralizes per-kind derived semantics: invalidation keys, branch inheritance disposition, retention eligibility, and snapshot supersession coupling.
- Branch inheritance now evaluates explicit per-kind rules (`message scoped`, `raw-prefix scoped`, `turn-summary scoped`, `durable checkpoint scoped`, `copy verbatim`, `omit`) rather than implicit catch-all derived copies.
- Latest-valid selection (`SuiteCheckpointSupport` + compaction checkpoint support) and `DerivedArtifactRetentionWorker` both resolve invalidation floors from the same per-kind contract map.

## Tool-pair safety (compaction)

The harness requires that **tool_use** / **tool_result** pairs are not split when compacting context. Head/middle/tail splitting is implemented in [`Compaction/ContextCompactionMessageSplit.swift`](Compaction/ContextCompactionMessageSplit.swift):

- Tail never starts with an orphaned `.tool` message; multi-call tool batches stay intact (fail-closed when IDs are missing).
- Head/middle boundary receives the same tool-pair protection.
- Latest user is pinned into tail only when that user is within the natural tail window (`naturalTailStart - tailMinMessageCount`); users deep in the compressible middle are not pinned.
- Successful compactions that save fewer prompt tokens than `compactionMinPromptTokenSavingsFraction` skip checkpoint persistence; consecutive low-savings runs open the same proactive compaction circuit as transform failures (`compactionCircuitBreakerMaxFailures`). Circuits apply to proactive auto-compaction only and are bypassed when `forceRunCompactionLLM` is set (reactive overflow retry). Manual `.slashCommand` / `.rest` compactions do not increment the auto low-savings counter; `.modelTool` does. The savings fraction compares symmetric char-per-token estimates; proactive trigger firing still prefers actual `lastPromptTokens`.

Unit coverage: `ContextEngineCompactionSplitTests`, `ContextCompactionOutputLayoutTests`.

## Compaction transcript partition

Split, checkpoint validity, and coverage all operate on the same filtered transcript. `DefaultContextEngine.executeTurnAssembly` calls `partitionForCompaction` once (in [`ContextCompactionCheckpoint.swift`](Compaction/ContextCompactionCheckpoint.swift)), strips harness injections via `transcriptForCompactionCoverage`, and passes the transcript to the input builder / flush / checkpoint paths. The transformer re-attaches `compactionInjectedPrefixMessages` to the split head. Unit coverage: `ContextCompactionTranscriptAlignmentTests`.

The harness’s **pruned** compaction checkpoints preserve `toolCalls` and `toolCallId` on `ContextCompactionMessageDTO` so rehydrated messages stay valid for the agent loop (see `ContextCompactionMessageDTO.prunedDTO` in [`Compaction/ContextCompactionCheckpoint.swift`](Compaction/ContextCompactionCheckpoint.swift)). **Summarized** checkpoints intentionally strip tool metadata where the synthesized text replaces raw tool traces.

Cross-link: [`ToolSystem/README.md`](../ToolSystem/README.md) (tool-result transform pipeline that feeds trim checkpoints). Unit coverage: `ContextCompactionCheckpointTests` (`prunedDTO factory preserves toolCalls…`).

## Harness-injected messages (compaction coverage)

`transcriptForCompactionCoverage` excludes harness-injected system messages via content prefixes in [`Compaction/HarnessInjectedMessagePrefixes.swift`](Compaction/HarnessInjectedMessagePrefixes.swift). Injection sites (`DefaultContextEngine`, `TurnLoop`) reference the same constants. Preferred future: structural `Message.harnessInjected` in SwiftAgentKit (requires library change). Regression coverage: `HarnessInjectionPrefixRegistryTests`.
