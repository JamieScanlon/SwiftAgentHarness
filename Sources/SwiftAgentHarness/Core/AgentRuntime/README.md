# Agent Runtime

This folder documents how this harnes maps to the harness **Agent Runtime** spec (inner imperative loop: assemble → model → stream → tools → append → stop). Runtime API ownership is exposed via `RuntimeStreamingOrchestrationService` (`APILayerChatRuntimeManaging`), wired directly to `AgentRuntimeSessionService` + `ConversationReplayService`.

**Loop implementation:** runtime-owned `TurnLoop` with four narrow ports (`RuntimeModelPort`, `RuntimeContextPort`, `RuntimeToolPort`, `RuntimeConversationPort`). `AgentRuntimeCoordinator` always routes through this path. See [`ARCHITECTURAL_EVALUATION.md`](ARCHITECTURAL_EVALUATION.md) for migration status.

## Boundary: SwiftAgentKit vs Runtime service host

| Concern | SwiftAgentKit (`SwiftAgentKitOrchestrator`) | Runtime service seam (`RuntimeStreamingOrchestrationService` → `AgentRuntimeSessionService`) |
|--------|-----------------------------------------------|----------------------|
| Tool/model streaming, tool execution ordering | `orchestrator.llm.stream` via `RuntimeModelPort`; tools via `RuntimeToolPort.dispatch` → `invokeTool`. | Runtime host builds `ToolManager` (providers). `TurnLoop` is the sole transcript writer per run. |
| Inner agentic iterations | Single `TurnLoop` iteration budget. | **`AgentRuntimeExecuting.executeTurn`** (`events` + terminal `result`). |
| Context assembly / compaction | N/A | **`ContextEngine` slot** (default: [`DefaultContextEngine`](../ContextEngine/DefaultContextEngine.swift)) via **`ContextProjectionService.transformedContextMessages`** → [`ContextAssemblyPipeline`](../ContextEngine/ContextAssemblyPipeline.swift) (**`assemble`** lifecycle API per iteration); compaction mutex acquired on **`ContextProjectionService`** |
| Conversation persistence | N/A | Runtime host delegates to [`ConversationManager`](../Managers/Conversation/ConversationManager.swift), SwiftData |
| Cancel user generation | Task cancellation on orchestrator path | Runtime host cancel paths request orchestrator run cancellation and preserve lane/terminal cleanup semantics. |
| Max iterations | Limits inside SwiftAgentKit agentic hub (`maxIterationsReached`) | **`AgentHarnessConfiguration`**: `maxAgenticStepsPerUpdate`, `maxTurnLoopContinuationRounds`, chatty/heuristic caps |

## Related modules

- **Context Engine**: [`ContextEngine/README.md`](../ContextEngine/README.md) — model-bound projection; invoked **per continuation round** in `startStreamingOrchestrationTask`, not only once per user send.
- **Tool System**: [`ToolSystem/README.md`](../ToolSystem/README.md) — registry/policy/dispatch boundaries vs SwiftAgentKit `ToolManager` (tool calls dispatched **after** assistant completion per orchestrator).
- **Sub-Agent Pool**: [`SubAgentPool/README.md`](../SubAgentPool/README.md) — **A2A** remote agents as harness-style delegate tools.
- **Model pool**: [`ModelCallScheduler`](../ModelPool/ModelCallScheduler.swift), [`ModelInvocationCoordinator`](../ModelPool/ModelInvocationCoordinator.swift), [`ModelManager`](../Managers/ModelManager.swift).
- **Runtime loop policy seams**:
  - `TurnLoopPolicyEvaluator` owns continuation guardrails and loop heuristics.
  - `ModeTerminationPolicyEvaluator` owns declarative termination-policy decisions (`bare-message` vs `terminal-tool`, recovery attempts, required tool choice posture).
  - `ModeRuntimePolicyEvaluator` owns runtime approval-stop overlays (`stopOnApprovalRequest`) and terminal-detail stability.
  - Tool approval policy is enforced in `ToolSystem` dispatch; the loop emits lifecycle around dispatch outcomes only.

## Stateless runtime (spec vs process)

The harness requires the **loop function** to be stateless across invocations. It uses a **single server process** with a [`HarnessRuntimeSession`](../ConversationManager/HarnessRuntimeSession.swift) **actor** holding orchestrator references and UI/session state. That is **session state**, not module-level globals inside the loop: concurrent **conversations** should use isolated IDs (`sendingConversationID`, `orchestratorConversationID`); separate session instances isolate selection entirely.

**Implementation:** Each **`startStreamingOrchestrationTask`** assigns the inner loop’s `Task` to **`generationTask`** (superseding a prior run via **`cancelInFlightStreamingGenerationOnly`**). **`streamingGenerationSequence`** ensures an older task cannot clear the slot after a newer send replaces it. Orchestrator assistant persistence runs in `stagedCommit` mode. Cancel paths trigger explicit run cancellation plus post-anchor tail strip: non-empty streamed partial assistant text is persisted with `finishReason: interrupted` before the `run_cancelled` marker, while incomplete tool cycles and empty/whitespace-only tails are still stripped by `RunTailStripping`.

**Orchestrator pool:** per-(conversation, model) entries live in [`OrchestratorPool`](OrchestratorPool.swift). `invalidate(conversationID:)` is a no-op while the first `acquire` for that conversation is still in `buildIfMissing` (no keyed entry yet), so a mode change racing that window may leave a stale-config orchestrator on first use. Lifecycle and token state are pool-entry scoped; no-arg lifecycle accessors fail closed when more than one entry is actively streaming.

## Stop conditions

Priority: **external cancel** > **natural terminal stop** > **bounded stop**.

| Harness bucket | signals |
|----------------|-----------------|
| External cancellation | User stop / `turnLoopStopRequestedConversationID`, task cancellation, `LLMRequestState.cancelled` |
| Natural stop | Declarative mode termination policy (`bare-message` or terminal halt-signal tool call such as `finish`, `ask_user`, `exit_plan_mode`, `declare_agent_build_complete`) |
| Bounded stop | `AgenticLoopState.maxIterationsReached`; **`HarnessRuntimeSession`** / `AgentHarnessConfiguration` caps (`maxTurnLoopContinuationRounds`, repeat-tool streak, chatty limits); SwiftAgentKit `maxAgenticStepsPerUpdate` when set |

Mode overlays that resolve to natural-stop details are now policy-evaluator owned (`stop_on_approval_request`, terminal-tool policy stops) instead of inline runtime-loop branches.

See [`HarnessTurnTermination.swift`](HarnessTurnTermination.swift) for a stable classification API used by tests and future telemetry.

## Interaction-mode runtime matrix

Mode loop behavior is driven by `ResolvedModeProfile.runtime` + tool metadata (`ToolRegistryEntry.haltsLoop`), not mode-name branches.

| Config parameter | Values | Affects | Runtime effect |
|------------------|--------|---------|----------------|
| `runtime.maxIterations` | `Int?` | Loop bound | Per-update cap on inner model/tool iterations; exceeding bound yields a bounded stop. |
| `runtime.stopOnApprovalRequest` | `Bool?` | Approval gating | When `true`, a turn may stop early with `stop_on_approval_request` if approval-required tools are detected. |
| `runtime.termination.policy` | `bare-message` \| `terminal-tool` | Natural termination rule | `bare-message`: no-tool assistant turn can naturally stop. `terminal-tool`: no-tool turn always enters recovery flow when no halting tool is called. |
| `runtime.termination.recovery.strategy` | `forced-tool-choice` | Recovery mechanics | Sets next iteration posture to required tool choice (`toolChoiceNext = .required`). |
| `runtime.termination.recovery.rollbackStalledTurn` | `Bool` | Transcript hygiene on recovery | When `true`, stalled bare assistant turn is removed before retry. |
| `runtime.termination.recovery.maxAttempts` | `Int` (>=1) | Recovery bound | Max consecutive stall recoveries before bounded stop (`termination_recovery_exhausted`). |
| `runtime.termination.recovery.reminder` | `off` \| `escalating` | Recovery nudge payload | Controls whether runtime injects continuation reminder messaging during recovery attempts. |
| `tools.allow` / `toolPolicy.<mode>` | allowlists | Callable loop-control tools | Mode must allow terminal tools (`finish`, `ask_user`, `exit_plan_mode`, etc.) and optional continuation tools such as `think` for required-tool turns. |
| `ToolRegistryEntry.haltsLoop` | `Bool` on tool descriptor | Halt-signal detection | Tool call with `haltsLoop == true` ends the loop via natural stop (`terminal_tool_halt_signal`). |

Notes:
- For `terminal-tool`, bare assistant turns now always use recovery semantics; required tool choice is driven by that recovery path.
- `think` is a non-halting no-op control tool: it satisfies required-tool posture but does not emit a halt signal.

Runtime persistence/wire alignment now uses `ConversationRunTerminalReason` in addition to coarse run status:

- terminal category: `externalCancellation`, `naturalStop`, `boundedStop`, `failure`
- optional bounded reason for guardrail exits (chatty/repeat/max-iterations/max-rounds)
- optional durable marker (`run_cancelled`) on cancelled lifecycle rows
- durable orphan repair marker (`run_orphaned`) on restart reconciliation for stale running runs

This keeps durable run APIs and runtime terminal mapping aligned with harness-style reason taxonomy.

## Tool dispatch

SwiftAgentKit executes tool batches and now supports explicit dispatch policy (`serial` vs `parallel`) and pending-handle outcomes.

- **Default remains conservative serial**: missing/unknown parallel-safety metadata resolves to serial; host `parallelDispatchEnabled` defaults to **false**.
- `TurnLoop` dispatches multi-tool turns via `RuntimeToolPort.dispatchBatch` → Kit `invokeTools`, mapping the per-turn `dispatchContract` (`parallelToolDispatchEnabled`, `plannerMode`). Single-tool and approval/delegate-gated batches fall back to serial per-call dispatch.
- Transcript commits remain **in call order**; lifecycle `tool.callCompleted` is emitted after each commit.
- The harness wires dispatch policy contract through `ToolPolicyConfiguration` (`toolPolicy.dispatch`) into orchestrator config/options.
- `TransformingToolProvider` now forwards `executeToolOutcome`, `parallelSafety`, and pending cancellation hooks so middleware stays compatible with pending-first providers.
- Pending completions are consumed from `SwiftAgentKitOrchestrator.pendingToolCompletions` and ingested back into the conversation transcript as tool messages.
- Production opt-in guidance: [Tool System README — Production gate](../ToolSystem/README.md#production-gate-x2-batch-parallelism).

## Facade type (`AgentRuntimeExecuting`)

Runtime entry is now explicit:

- **`AgentRuntimeExecuting`** defines:
  - `runTurn(_:)` for terminal turn execution semantics
  - `executeTurn(_:)` as the canonical unified primitive (`AsyncStream<RuntimeLifecycleEventPayload>` + terminal `AgentRuntimeRunResult`)
- **`AgentRuntimeRunContext`** carries per-invocation state (`conversationID`, `runID`, runtime turn configuration, orchestrator handle). `runtimeLifecyclePublish` is compatibility-only and not used by the default stream-primary execution path.
- **`AgentRuntimeRunResult`** returns terminal outcome plus classified error-policy metadata.
- **`AgentRuntimeTurnExecution`** bridges runtime and transport: runtime emits one lifecycle stream while preserving one final result contract.
- **`AgentRuntimeCoordinator`** is the runtime entrypoint and delegates loop execution to `TurnLoop` via `AgentLoopPorts` on **`AgentRuntimeSessionService`** (not the session actor). After-turn context-engine lifecycle (`afterTurnContextEngineLifecycle`) runs on **all** turn exits, including throws; `terminalReason` is `nil` when the loop did not reach a terminal return.
- Tool/approval runtime callbacks now route through dedicated policy helper seams (`ConversationToolModePolicyServicing` + runtime approval helper) instead of embedding approval-store logic directly in loop code paths.

**`HarnessRuntimeSession`** remains the session actor and owns UI/session lifecycle fields, while runtime execution internals live in runtime-owned seams (`AgentRuntimeSessionService`, `TurnLoop`, `RuntimeTurnTerminalHandler`, `RuntimeTurnStreamTransportAdapter`) and interact with session state via injected typed port protocols (`ConversationMessagingPort`, `OrchestratorSessionPort`, etc.).

## Runtime lifecycle publication

Runtime now publishes first-class conversation-topic lifecycle events (`semanticKind: runtimeLifecycle`) via `AgentRuntimeLifecycleEmitter`:

- `turn.started`
- `loop.iterationStarted` -> `model.callStarted` -> `model.callCompleted`
- optional `tool.callStarted` / `tool.callCompleted`
- `loop.iterationCompleted`
- terminal: `turn.completed` / `turn.cancelled` / `turn.bounded`

Ordering is emitted deterministically by `runAgentBuildStreamingOrchestrationCore` (source ordering) and `startStreamingOrchestrationTask` now consumes `executeTurn.events` live as the single runtime transport input (including `toolUsageSummary` derivation) before teardown. `seq` remains the transport counter assigned by `ConversationEventsTopicHub`.

## Error policy matrix

`AgentRuntimeErrorPolicy` classifies runtime failures and centralizes handling semantics used by `startStreamingOrchestrationTask`:

- **cancellation** (`CancellationError`) -> `failTurn` + terminal `.cancelled`
- **model/pool failure** (`LLMError`, `ModelPoolError`, `OrchestratorError`) -> `failTurn` + terminal `.failed`
- **tool error** (`AgentRuntimeToolError`) -> `continueLoop` handling class (coordinator maps to non-terminal completion when surfaced as runtime exception)
- **runtime fault** (unexpected loop/invariant errors) -> `failTurn` + terminal `.failed`

This keeps status mapping explicit while preserving existing transport-level terminal statuses.

## Compaction retry boundary

Context-window reactive retry is handled inside `TurnLoop` via `ContextWindowRecoveryCoordinator`; the orchestrator no longer runs the agent loop.

Architectural evaluation: [`ARCHITECTURAL_EVALUATION.md`](ARCHITECTURAL_EVALUATION.md). Migration history and residual out-of-scope items: [`AGENT_RUNTIME_MIGRATION.md`](../../../../../Documentation/AGENT_RUNTIME_MIGRATION.md).
