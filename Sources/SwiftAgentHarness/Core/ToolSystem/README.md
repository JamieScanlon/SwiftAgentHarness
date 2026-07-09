# Tool System

This folder implements the harness **Tool System** spec. Model-driven tool visibility, policy, and dispatch shaping route through canonical `RegisteredToolDescriptor` → `ToolRegistryEntry` projection seams, while execution remains in **SwiftAgentKit** (`ToolManager`). The harness consumes canonical registered descriptors (`allRegisteredTools`) and supplies policy + result shaping overlays. In-process tool providers live in this folder (`ConversationsToolProvider`, `AgentPlanToolProvider`, `TerminationToolProvider`, and others).

## Gateway contracts

- **`DefaultToolSystemGateway`** is the Tool System boundary for:
  - merged tool discovery (`allRegisteredToolsForTurn`)
  - model-facing tool filtering (`effectiveToolsForConversation`)
  - API-facing listing (`availableToolsForAPI`) — conversation-scoped calls use the same per-turn `evaluateAvailability` / `isAdvertisedToModel` semantics as model-facing lists; session-global listing uses conservative default turn configuration (tools/agents enabled, no pre-approvals) and is not authoritative for per-turn UI
  - dispatch contract derivation (`dispatchContract`)
- **`ToolRegistryEntry`** is the typed registry row used by the gateway (tool definition + source + effect/parallel/policy metadata + explicit execution-environment descriptor + normalized schema summary/fingerprint/version fields for API/WS contracts).
- Execution environment contract: each entry resolves deterministic `executionEnvironment` (`kind`, `adapterID`, `isolationLevel`) from canonical descriptor projection, then runs through one adapter seam (`ToolExecutionEnvironmentAdapting`) before gateway/policy consumers read it.
- Canonicalization invariant: `ToolRegistryEntry(descriptor:)` is a pure projection; Tool System no longer applies name-based fallback metadata inference or app-layer descriptor reconstruction from raw `ToolDefinition`.
- Parallel dispatch matrix invariant: host parallel execution is enabled when `toolPolicy.parallelDispatchEnabled` is true and no effective entry has unknown static capability metadata; per-call `parallelSafety(for:)` predicates (via `ToolCallCapabilityClassifier` for polymorphic tools like `bash` and `process`) drive `mixedDeterministic` batch planning in SwiftAgentKit. Static registration metadata remains fail-closed for polymorphic tools; call-time classification determines read fan-out and call-level approval severity.

### Production gate (X2 batch parallelism)

Batch-level parallelism is **opt-in**. Defaults remain conservative:

- `toolPolicy.dispatch.parallelEnabled` defaults to **`false`**
- `toolPolicy.dispatch.plannerMode` defaults to **unset** (`nil` → serial unless parallel is enabled, in which case the gateway defaults planner to `mixedDeterministic`)

When enabling in PromptConfig:

```json
"toolPolicy": {
  "dispatch": {
    "parallelEnabled": true,
    "plannerMode": "mixedDeterministic"
  }
}
```

`TurnLoop` routes multi-tool turns through Kit `invokeTools` with the per-turn `dispatchContract` (`parallelToolDispatchEnabled` + `plannerMode`). Approval-gated, deny-gated, or sub-agent delegate calls force **serial fallback** for that batch.

**Supported planner modes for hosts:** `serial` and `mixedDeterministic` (partition semantics — order-preserving groups of contiguous concurrency-safe calls). `allParallel` is **deprecated and ignored**: it still parses from PromptConfig for backward compatibility but is always remapped to `mixedDeterministic` at the harness dispatch boundary with a structured warning. No model-turn batch reaches Kit with `plannerMode: allParallel`. See [parallel-execution.md](../../../../harness-template/core/tool-system/parallel-execution.md) for floor vs partition semantics.

## Description change control (S4)

Tool `description` strings are **behavioral surface**, not documentation polish. They are sent to the model in the tool block and can change tool-selection behavior with no test failure. Treat edits like system-prompt changes: review for scope, safety, and confusion with sibling tools. MCP/A2A descriptions are third-party passthrough unless the harness explicitly overrides them.

Process: [docs/process/tool-description-change-control.md](../../../../docs/process/tool-description-change-control.md) (author/reviewer checklists, changelog rule, file inventory).

## Boundary: SwiftAgentKit vs harness

| Concern | SwiftAgentKit | Harness / host |
|--------|----------------|----------------|
| Tool dispatch / execution | `ToolManager` from `[ToolProvider]`; MCP and A2A inside `SwiftAgentKitOrchestrator` | [`OrchestratorRuntimeService.setupOrchestrator`](../ConversationManager/OrchestratorRuntimeService.swift) builds providers; MCP/A2A from [`ConversationStartupService`](../ConversationManager/ConversationStartupService.swift) |
| In-process tools | `ToolProvider` protocol | This folder: `ConversationsToolProvider`, `AgentPlanToolProvider`, `TerminationToolProvider` (`finish`, structured `ask_user`, non-halting `think(snapshot)`), `ModeTransitionToolProvider` (`enter_plan_mode`, `exit_plan_mode`), skills wrappers, optional `ContextCompactionToolProvider` |
| Host-supplied tools | `ToolProvider` protocol | Non-harness providers are injected by the host via `OrchestratorRuntimeService.installAdditionalToolProviders(_:)` ([`HarnessToolProviderSeam`](HarnessToolProviderSeam.swift)); the factory receives a per-turn `HarnessToolProviderContext` (active conversation, workspace root, logger). Example: `PersonalMessagingToolProvider` is registered by the app, not the harness |
| Gateway allow / deny (hard enforcement) | N/A | `ToolPolicyConfiguration` (host `PromptConfig.json`) + per-conversation `ModelConversation.disabledToolNames` + send flags via [`DefaultToolSystemGateway`](ToolSystemGateway.swift) |
| Skill gates | N/A | [`ModeProfileSkillsSlice`](../ConversationManager/InteractionModes/ResolvedModeProfile.swift) + `SkillPolicySkillsToolProvider` |
| Runtime result shaping (middleware seam) | Raw `ToolResult` from provider | [`TransformingToolProvider`](TransformingToolProvider.swift) wrapping each provider; host-supplied deterministic middleware mounted via `OrchestratorRuntimeService.registerAgentToolResultMiddleware(_:)` (no LLM call on this seam) |
| Parallelism + pre-dispatch policy | Orchestrator planner/policy seams (`dispatchPlannerMode`, `preDispatchPolicyEvaluator`) | Host maps `toolPolicy.dispatch` into orchestrator config/invocation options, enforces pure-only parallel eligibility from effective entry metadata, and derives per-turn pre-dispatch decisions from gateway availability snapshots |
| Descriptor validation | `ToolManager(descriptorValidationMode:)` | Validation mode is configured from `toolPolicy.descriptorValidationMode` (`warning` default, `strict` opt-in) |
| Approval contract parity | `ToolPreDispatchPolicyDecision.requireApproval` + `ToolApprovalSpec` | Tool System emits structured approval metadata (`title`, `description`, `severity`, `timeoutMs`, `timeoutBehavior`) and runtime resolves timeout defaults deterministically through `ToolApprovalStateStore` |
| Elevated execution semantics | pre-dispatch decision `.elevated` | Elevated path carries explicit execution-policy provenance (`toolPolicy.elevatedExecutionPolicy`) through pre-dispatch reason codes, policy context, and `tool.elevatedExecuted` lifecycle emission |
| Execution-environment policy ownership | provider/transport-specific behavior | Tool System gateway composes environment-level policy (`toolPolicy.executionEnvironment`) with allow/deny/approval/escalation decisions from one normalized descriptor contract (`kind` + `adapterID` + `isolationLevel`), including adapter-level selectors where needed |
| Runtime lifecycle audit parity | lifecycle hooks vary by invocation surface | Model, slash, and async-completion lifecycle payloads flow through one fanout seam (topic + trace + derived audit), with shared payload shape and validation |
| Call-level traceability + provenance | transport-specific call ids | Lifecycle/trace/audit contracts include per-call IDs (`toolCallID`, completion/delegate IDs) and redaction-safe argument/result provenance fields (digest/byte-count/redaction/truncation) |

**Statement:** SwiftAgentKit owns tool **execution**; the harness owns discovery, policy, dispatch contracts, result shaping, and lifecycle audit surfaces.

## Host integration

At boot, the host app typically:

1. Loads **`ToolPolicyConfiguration`** from `PromptConfig.json` (allowlists, dispatch mode, descriptor validation, elevated execution policy).
2. Registers in-process **`ToolProvider`** implementations and wraps them with **`TransformingToolProvider`** middleware.
3. Wires **`DefaultToolSystemGateway`** with orchestrator registry access, mode/skill policy, and per-conversation disabled-tool state.
4. Connects approval resolution (`ToolApprovalRuntimeService`, `ConversationToolModePolicyRuntimeService`) to REST and timeout paths.

## Gateway vs prompt-only guidance

- **Gateway (enforced):** `ToolPolicyConfiguration` allowlists in **PromptConfig.json**; per-conversation **disabled** tool names; **send** options (`enableTools`, `enableAgents` for A2A tool names). The model cannot “talk its way” into a blocked tool if it is not in the filtered set passed to the orchestrator.
- **Prompt-only:** system prompt / skills text that *discourages* tool use is **not** a substitute for the allowlist; both layers are recommended (harness: prompt injection does not defeat Gateway policy).

## Halting-tool contract

- Loop-halting tool semantics are defined on `ToolRegistryEntry.haltsLoop`, not mode-name branches in runtime code.
- Canonical halting tools are `finish`, `ask_user`, `exit_plan_mode`, and `declare_agent_build_complete`.
- `think` is intentionally non-halting (`haltsLoop == false`) and is used as a continuation/no-op tool for required-tool-choice rounds.
- `ask_user` returns a structured prompt payload (`question`, `options`, `allowMultiple`, optional `defaultOptionID`) in `ToolResult.metadata.askUser` for UI/API consumers.

## Approval and elevated lifecycle

- Approval-gated tools are **advertised** to the model (`isAdvertisedToModel`); dispatch enforces approval when the model calls them (harness snapshot gate + live pre-dispatch evaluator backed by `ToolSystemGateway` and `ToolApprovalStateStore`).
- `tool.approvalRequired` always includes structured approval contract metadata and timeout/default-action semantics.
- Pending approvals are recorded in `ToolApprovalStateStore` and auto-resolve by policy timeout (`autoDeny` / `autoApprove`) with canonical `tool.approvalResolved` emission.
- API-driven approval resolution (`POST /api/conversations/{id}/tool-approvals`) and timeout-driven resolution route through `ConversationToolModePolicyService` (`ConversationToolModePolicyServicing`) backed by **`ConversationToolModePolicyRuntimeService`**, with runtime approval state in `ToolApprovalRuntimeService`.
- Elevated executions use the configured execution policy seam (`toolPolicy.elevatedExecutionPolicy`) and emit provenance-aligned `tool.elevatedExecuted`.

## Audit and shaping parity

- Runtime lifecycle publish uses a single fanout seam that consistently performs conversation-topic publish, trace projection, and derived-audit persistence.
- `tool.callStarted` / `tool.callCompleted` / `tool.completionAnnounced` carry per-call correlation (`toolCallID`, delegate/completion ids) and redaction-safe provenance metadata (argument/result digest + byte count + redaction tier + truncation flag).
- Tool lifecycle/trace payloads include execution-environment provenance (`executionEnvironmentKind`, `executionEnvironmentAdapterID`, `executionIsolationLevel`) for diagnostics across model + slash paths.
- Correlation contract for tool lifecycle fanout is normalized across topic + trace + derived audit sinks (`runID`, `toolName`, `toolCallID`, optional `delegateHandleID` / `completionAnnounceID`) so operational joins are deterministic across model, slash, and pending-completion surfaces.
- Model turns build one authoritative per-turn Tool System snapshot (availability decisions + advertised tool set + dispatch contract from fully-allowed entries) and install a live pre-dispatch evaluator at orchestrator bootstrap.
- `ToolResultFormattingStack` applies stage-aware shaping with one canonical policy source: character + byte caps, metadata byte caps, deterministic metadata placeholders, and runtime/persistence/compaction-specific image/marker behavior.
- **Oversized tool results (R1):** when `toolResultFormatting.spillEnabled` and on-disk session store are present, runtime delivery **spills** full output to `agents/<agentId>/sessions/<conversationId>/tool-results/<toolCallId>.txt` and returns a bounded preview envelope (~2KB) plus recoverable path. `read_file` allowlists the conversation spill directory. Lossy `[tool result truncated]` markers are fallback only when spill is disabled or unavailable. `read_file` / `glob` / `grep` are **spill-exempt**.
- **Exact-content observations (R2):** registry entries tagged `exact-content-observation` bypass lossy line/char/byte and metadata trim at **runtime + persistence** only (`read_file`, `activate_skill`, `get_plan`, `ask_user`, sub-agent delegates). `read_file` self-bounds via optional `offset`/`limit` (256KB cap per call). **Compaction-protected** entries (sub-agent delegates) are never cleared by compaction hygiene; re-derivable reads stay compactable.
- Inline image payload sanitization applies consistently to both result content and structured metadata before runtime delivery, persistence, and compaction summarization stages.
- Compaction path keeps deterministic recency behavior through existing pruning/hygiene policy while using explicit compaction-stage placeholders for older payload/image content, and cache-aware TTL pruning preserves assistant/tool rows to avoid breaking tool-pair integrity.

## Tool list ordering (discovery)

The LLM-facing list is **filtered** then **sorted by `ToolDefinition.name`** (Unicode scalar string order) in [`DefaultToolSystemGateway`](ToolSystemGateway.swift) so ordering is **deterministic** across runs (harness: stable prompt-cache / discovery prefixes).

Merged orchestrator descriptor lists (`allRegisteredToolDescriptorsForOrchestration`) are sorted by tool name after combining SwiftAgentKit’s `allRegisteredTools` with local baseline descriptors when needed.

API listing and runtime entry resolution both use the same descriptor-source policy seam (`OrchestrationToolCatalog.registryEntriesForListing` / `allRegisteredToolDescriptorsForOrchestration`) so fallback behavior is explicit and consistent when no orchestrator-backed registry is available yet.

Sub-agent transport ownership follows the same contract: transport resolution is adapter-first (from `executionEnvironment.adapterID`) with deterministic environment-kind fallback, and resolved transport metadata is carried into launch planning.

## Result pipeline (runtime middleware vs persistence middleware)

- **Runtime delivery stage:** `TransformingToolProvider` applies ordered middleware on results before they are returned to the orchestrator/model path.
  - Order 50: subdirectory hint tracking
  - Order 100: host-registerable deterministic middleware (`registerAgentToolResultMiddleware(_:)`) — the runtime-neutral interception point for reshaping tool output before the model sees it. No LLM call; the eager LLM tool-result summarizer that previously lived here was removed (spec divergence). A content-rewriting middleware mounted here feeds the otherwise-dormant `tool_result_trim` checkpoint.
  - Order 200: `external-content-envelope` — [`ToolResultExternalContentMiddleware`](../../cross-cutting/Provenance/ToolResultExternalContentMiddleware.swift) wraps non-exempt tool output via [`ExternalContentEnvelope`](../../cross-cutting/Provenance/ExternalContentEnvelope.swift) immediately before the model sees it.
- **Persistence stage:** the runtime session applies a separate ordered persistence-stage middleware pipeline before durable tool-result append/checkpoint writes.
- **Durable append:** conversation/transcript persistence owns message journal and projection writes after middleware stages complete.

## Slash-command consumer boundary

- Tool System scope is **narrow** for slash surfaces: only slash commands that resolve to **tool dispatch** should enter Tool System dispatch/evaluation.
- Non-tool slash kinds (`local`, `prompt`, `directive`, `skill`) are command-surface concerns and are not Tool System responsibilities.
- Implemented contract for tool-dispatch slash commands uses direct orchestrator invocation (`invokeTool`) with `source: .command` and raw envelope forwarding (`argMode: raw`) so Tool System policy/audit seams stay consistent with model-originated tool calls, including shared execution-environment context and policy evaluation.

## Compaction hygiene interaction

- Context compaction deterministic hygiene runs through a single staged policy surface before compaction summarizer calls.
- Tool-result content pruning remains one stage in that pipeline and is explicitly toggleable via `ContextCompactionConfiguration.deterministicToolResultPruningEnabled`.
- Attachment/document/image hygiene stages are additive and policy-gated, so tool dispatch semantics remain unchanged while compaction input shaping becomes explicit and testable.

## Related modules

- **Agent Runtime:** [`../AgentRuntime/README.md`](../AgentRuntime/README.md) — inner loop that **dispatches** tool calls after assistant completion.
- **Sub-Agent Pool:** [`../SubAgentPool/README.md`](../SubAgentPool/README.md) — remote **A2A** delegation vs harness pool (registry, transports, delegate tools).
- **Context Engine:** [`../ContextEngine/README.md`](../ContextEngine/README.md) — context assembly; **tool-pair** integrity with compaction checkpoints.
- **Model pool:** [`../ModelPool/ModelCallScheduler.swift`](../ModelPool/ModelCallScheduler.swift), [`../ModelPool/ModelInvocationCoordinator.swift`](../ModelPool/ModelInvocationCoordinator.swift).

## Diagnostics types

- [`ToolAvailabilityBlockReason`](ToolAvailabilityBlockReason.swift) — labels for **why** a tool might be excluded from the model-facing list (logging/tests); filtering logic stays in `DefaultToolSystemGateway`.
