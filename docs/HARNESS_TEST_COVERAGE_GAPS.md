# Harness test coverage gaps (tests removed from SileniaAIServer)

While trimming SileniaAIServer's test target to only cover **that project's** code, tests
were removed that were actually exercising **SwiftAgentHarness** types. This document tracks
every removed test and the port status into SwiftAgentHarness.

Status legend:

- **Covered** — SwiftAgentHarness has an equivalent test; nothing to port.
- **Ported** — coverage added in this repo (see linked test file).
- **GAP** — not yet ported.
- **Obsolete** — exercised an API removed in CR-D (eager LLM tool-result summarization); do not port.

Harness pin verified for the original audit: `10c41d8` (`SileniaAIServer/Package.swift`).

---

## `AgentHarnessConfigurationTests.swift`

Target: `Tests/SwiftAgentHarnessTests/Config/AgentHarnessConfigurationDecodeTests.swift`

| Removed test | Behavior | Status |
|---|---|---|
| `defaultStrictPromptsEnabled` | `AgentHarnessConfiguration.default.strictAgentHarnessPrompts == true` | **Ported** |
| `harnessJSONClampsBuildRoundsHighValues` | `maxTurnLoopContinuationRounds` clamps `600 → 500` | **Ported** |
| `harnessJSONClampsCorrectionRetries` | `maxCorrectionRetries` clamps `999 → 20` | **Ported** |
| `harnessJSONMissingKeyUsesDefault` | absent keys → `maxTurnLoopContinuationRounds == .max`, `useAgentLoop == true` | **Ported** |
| `defaultMaxTurnLoopContinuationRoundsUnlimited` | `default.maxTurnLoopContinuationRounds == .max` | **Ported** |
| `harnessJSONPreservesPoolTTL` | `orchestratorPoolIdleTTLSeconds` override (`120`) preserved | **Ported** |
| `harnessJSONPreservesPoolMaxEntries` | `orchestratorPoolMaxEntries` override (`8`) preserved | **Ported** |
| `harnessJSONPreservesRepeatStreak` | `repeatToolCallStreakThreshold` override (`7`) preserved | **Ported** |

---

## `ConversationTransformConfigurationTests.swift`

Target: `Tests/SwiftAgentHarnessTests/Config/ConversationTransformConfigurationDecodeTests.swift`

| Removed test | Behavior | Status |
|---|---|---|
| `defaultsEnableHooks` | `.default` enables all three hook toggles for every `InteractionMode` | **Ported** |
| `parserClampsTimeoutRange` | `transformTimeoutSeconds` clamps `0→1`, passes `999`, clamps `99999→3600` | **Ported** |
| `parserPreservesHookToggles` | legacy top-level toggles apply identically to chat/plan/agent | **Ported** |
| `parserPerModeOverridesMergeWithBaseline` | per-mode override objects merge over the legacy baseline | **Ported** |
| `parserPartialPerModeInheritsBaseline` | partial per-mode object inherits unspecified hooks from baseline | **Ported** |
| `contextCompactionDefaults` | full `ContextCompactionConfiguration.default` value assertions | **Ported** |
| `parserPreservesContextCompaction` | explicit `contextCompaction` JSON values are preserved | **Ported** |
| `parserAcceptsSnakeCaseMaxRecentToolResults` | `max_recent_tool_results` snake_case decodes | **Ported** |
| `parserAcceptsSnakeCaseMaxRecentPerNameToolResults` | `max_recent_per_name_tool_results` snake_case decodes | **Ported** |
| `parserClampsSummarizerMaxOutputToPersistenceCeiling` | old `budget × 1.5` decode clamp | **Obsolete** (covered by `decodeNoLongerClampsSummarizerMaxOutput`) |

---

## `ContextCompactionTransformerTests.swift`

Target: `Tests/SwiftAgentHarnessTests/Core/ConversationManager/ContextCompactionTransformerTests.swift`

### Verified already covered (layout / checkpoint / pruning suites)

| Removed test | Status |
|---|---|
| `noOpOnContinuationPhase` | **Ported** (direct transformer test) |
| `compactionPreservesSystemAndFinalAndCaps` | **Covered** — `ContextCompactionOutputLayoutTests` |
| `summarizerFailureFallback` | **Ported** (direct transformer test) |
| `branchNoCheckpointShortCircuits` | **Covered** — `ContextCompactionOutputLayoutTests`, checkpoint progression |
| `branchNoCheckpointFallsThroughToSummarizer` | **Covered** — `ContextCompactionOutputLayoutTests` |
| `branchPrunedCheckpointSkipsDeterministicPrune` | **Covered** — `ContextCompactionCheckpointProgressionTests` |
| `branchSummarizedCheckpointNewTailShortCircuits` | **Covered** — checkpoint progression |
| `summarizerReceivesPrunedToolResults` | **Ported** (capturing summarizer) |
| `summarizerReceivesEffectiveMiddleWhenHintsProvided` | **Ported** (capturing summarizer) |
| `provenanceSourcesCoverFullRawMiddleWhenHintsProvided` | **Ported** (transformer provenance assertion) |
| `deterministicHygieneToolPruningToggle` | **Ported** (transformer E2E with pruning disabled) |
| `deterministicHygieneTrimsDocumentAndImages` | **Ported** (transformer E2E with attachment hygiene) |

### Ported transformer-level gaps

| Removed test | Status |
|---|---|
| `identifierPreservationPromptBlockModes` | **Ported** |
| `compactionSchedulingModelIDDeterministic` | **Ported** |
| `compactionSchedulingModelIDNormalization` | **Ported** |
| `compactionSchedulingWrapperUsesBackgroundPriority` | **Ported** |
| `compactionSchedulingWrapperNoOpWhenNil` | **Ported** |
| `handoffTemplateIncludesIdentifierBlock` | **Ported** |
| `turnSummaryPreservesUserPromptAndSummarizesOutcome` | **Ported** |
| `turnSummaryFailureFallsBackToOriginalTurn` | **Ported** |
| `branchSummarizedCheckpointNoNewTail` | **Ported** |
| `focusedStrategyFiltersMiddle` | **Ported** |
| `cacheAwarePruningRespectsTTLAndStablePrefix` | **Ported** |
| `cacheAwarePruningPreservesToolPairRows` | **Ported** |
| `providerFallbackChainForCompactionSummarizer` | **Ported** |
| `summarizedCheckpointDoesNotDoubleCarryPriorSummary` | **Ported** |

### Obsolete (do not port)

| Removed test | Status |
|---|---|
| `toolResultNoOpUnderThreshold` | **Obsolete** |
| `toolResultSummarizesAndPreservesFields` | **Obsolete** |
| `toolResultSummarizerFailureFallsBack` | **Obsolete** |
| `compactionFormattingUsesConfiguredBasePolicy` | **Obsolete** |
