# AgentRuntime Layer Review

I read the template's agent-runtime page and the layer implementation (loop, policy evaluators, contracts, coordinator, session service + streaming/lifecycle extensions, terminal handler, emitters). Verdict up front: **the runtime now owns the inner loop** via `TurnLoop` and four narrow ports; SwiftAgentKit is used as a model/tool adapter, not as the iteration owner. Termination-policy machinery closely conforms to the template.

## What's right

`ModeTerminationPolicyEvaluator` is almost exactly the template's decision function: pure, returns stop/continueLoop/recover/bounded + toolChoiceNext + rollback + reminder, stall counter resets on tool-calling turns, separate stall budget from the iteration budget, distinct bounded reasons. Halt signals are resolved by asking the tool system (`runtimeIsHaltingToolCall` against registry entries), so the runtime stays free of tool names. The loop never branches on mode id. Terminal reasons are a proper taxonomy (cancel / natural / bounded-with-subreason / failure), error classification distinguishes tool vs model/pool vs runtime vs cancellation with per-class handling, and `executeTurn` returning `AgentRuntimeTurnExecution { events: AsyncStream, result: Task }` is the right Swift translation of pi-mono's `EventStream<Event, Result>`. Provenance digests instead of raw tool payloads in lifecycle events is a thoughtful touch the template doesn't even demand.

**Legacy fork removed (2026-06):** `AgentBuildTurnLoop`, `ToolTurnPolicyCoordinator`, message-listener reconciliation (append drain, observed-output fallback, drain gate), and `useLegacyOrchestratorLoop` are deleted. `AgentRuntimeCoordinator` always routes through `TurnLoop` + `AgentLoopPorts`. `AssistantMessageAccumulator` is the sole assistant writer per iteration.

## Remaining structural notes

- **Two iteration budgets (orchestrator vs runtime)** still exist at the SwiftAgentKit config layer (`maxAgenticStepsPerUpdate` vs `maxTurnLoopContinuationRounds`). `TurnLoop` owns the outer budget; orchestrator inner steps are not used on the agent-loop path for tool execution.
- **Session actor state** (`activeStreamingConversationID`, `generationTask`, stop-request set) is session-scoped, not module globals — document 1:1 active-conversation assumption unless product requires concurrency.
- **Full orchestrator inversion** (orchestrator as pure model adapter with zero agentic hub) remains the long-term end-state; see [`INVERTED_LOOP_SKETCH.md`](INVERTED_LOOP_SKETCH.md).

## Resolved (formerly open)

| Item | Resolution |
|------|------------|
| Reconciliation tax (listener, drain, fallback) | Deleted with legacy fork |
| God protocol (`AgentBuildTurnLoopServicing`) | Collapsed to four ports + slim coordinator protocol |
| Recovery reminder `role: .user` | System-role ephemeral block |
| Stop-request clobber | `Set<UUID>` |
| Cancel strip discards completed turns | `RunTailStripping` preserves completed bare assistant; partial/incomplete stream not appended |
| Drain-gate race | Machinery deleted |
| Fire-and-forget `cancelGeneration` | Awaited; cancellation propagates to `executeTurn` + `TurnLoop` |
| `model.callStarted` before dispatch | Emits on first stream event |
| Think-tool / forced-choice trap | Bounded stop when `toolChoice == .required` and no callable tools |
| Approval gate in loop body | Dispatch is single authority via `ToolSystem` + `AgentLoopToolDispatch` |
| `toolCallStarted` after execution | Fixed: emits before dispatch |

## Swift hygiene (partial)

| Item | Status |
|------|--------|
| Typed lifecycle `AgentRuntimeLifecycleEmit` enum | Done (typed payload structs; legacy `emit(name:…)` removed) |
| Duplicate `emitOrchestrationState…IfBound` wrappers | Deduped |
| `withLifecycleEmitter` copy hazard | Fixed via `var` + struct copy |
| `Section4RuntimeContracts.swift` | Renamed → `AgentRuntimeDispatchContracts.swift` |
| `AgentBuildLoopPolicyEvaluator` | Renamed → `TurnLoopPolicyEvaluator` |
| `messageStream` / `serviceRuntimeMessageStream` | Both delegate to `buildRuntimeMessageStream` (protocol surface) |
| `maxTurnLoopContinuationRounds` naming | Done (mechanical rename from `maxAgentBuildContinuationRounds`) |

## Migration progress

Status tracker for the agent-loop execution plan. Design reference: [`INVERTED_LOOP_SKETCH.md`](INVERTED_LOOP_SKETCH.md).

| Item | Status | Notes |
|------|--------|-------|
| Phase 0 conformance fixes | done | system-role reminder, stop-request `Set`, cancel strip preserves completed turns, drain-gate race fix |
| Four ports + accumulator | done | `AgentLoopPorts`, `AssistantMessageAccumulator`, session adapters |
| TurnLoop single path | done | Legacy fork deleted; coordinator always constructs `TurnLoop` |
| Tool choice wiring | done | `toolInvocationPolicy` in `AgentLoopLLMStreaming`; bare-assistant rejection in `TurnLoop` when `.required` |
| Lightweight model resolve | done | `resolve` returns handle only; `setupOrchestrator` once in `bootstrap` |
| Dispatch snapshot gate | done | `AgentLoopToolDispatch` checks `effectiveEntries` + availability |
| Approval parity | done | dispatch is single authority; blocking wait in `dispatchFn`; live evaluator config |
| Active turn config for live evaluator | done | per-run `AgentRuntimeTurnConfiguration` registry |
| Accumulator hygiene | done | reasoning not persisted; final `LLMResponse.images` on `Message` |
| Runtime hygiene | done | awaited `cancelGeneration`; agent-loop partial stream `.unbounded` |
| Cancel strip semantics | done | incomplete stream not appended; `RunTailStripping` for completed turns |
| Parity tests | done | `AgentLoopParityTests`, `TurnLoopConformanceTests`, section-6 on default harness |
| Reconciliation machinery deleted | done | listener/drain/fallback removed |
| God protocol collapsed | done | `AgentBuildTurnLoopServicing` removed |
| Agent-loop cancel durability | done | section-6 cancel test on default harness |
| Context projection gating | done | `gatingOverride` on `ContextProjectionTransformServicing`; agent-loop downcast removed |
| Approval transcript repair | done | synthetic `tool` rows for gated batch calls |
| Compaction config parity | done | `AgentLoopPorts.contextCompaction` wired from session config |
| Stream retry gating | done | compaction retry only when `!publishedStreamDeltaThisAttempt` |
| Approval block dispatch | done | blocks on `ToolApprovalStateStore.waitForResolution` when configured |
| toolCallStarted bracketing | done | started before dispatch; completed after execution |
| BoundModelIDCache | done | `OSAllocatedUnfairLock`-guarded |
| Model ensure-bind | done | `SessionRuntimeModelPort.resolve` rebinds on model id change |
| model.callStarted timing | done | first stream event |
| Required-tool unsatisfiable guard | done | bounded stop with `required_tool_choice_unsatisfiable` |

### Resolved open questions

| Question | Answer |
|----------|--------|
| Step cap without internal tool execution? | Not available — direct Phase 3 path chosen |
| `partialFragmentsStream` / wire encoding? | Reuse `ModelPoolContentDeltaMapping` + `ConversationTopicWireEncoding` |
| System prompt in Context Engine? | Deferred — `SystemPrompt` stays on model handle |
| `ephemeralTail` role | System-role ephemeral block (Phase 0) |

## References

- [`INVERTED_LOOP_SKETCH.md`](INVERTED_LOOP_SKETCH.md)
