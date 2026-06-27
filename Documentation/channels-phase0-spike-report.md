# Phase 0 Spike Report — Message Output Verb

## Summary

**Boundary decision: Outcome A — harness-only.** No SwiftAgentKit change required for the message output verb.

`TurnLoop` (not the orchestrator agentic hub) is the sole assistant transcript writer. The harness already owns streaming (`publishAgentLoopDelta`), finalization (`AssistantMessageAccumulator`), and persistence (`ports.conversation.append`). Free-form assistant text and `message` tool argument fragments both flow through harness-controlled seams.

## What was traced

| Seam | Location | Role |
|------|----------|------|
| Stream deltas | `TurnLoop.publishStreamDelta` → `AgentRuntimeCoordinator.publishAgentLoopDelta` | Emits `.text`, `.toolCall(argumentsFragment:)`, etc. |
| Partial fan-out | `AgentRuntimeSessionService+AgentLoop.swift:170-259` | Maps partials to WS topic payloads |
| Assistant finalize | `AssistantMessageAccumulator.finalize()` | Builds `Message` + `HarnessMessageEnvelope` |
| Transcript append | `TurnLoop.swift:224-235` | Appends assistant after each iteration |
| Orchestrator persistence | `OrchestratorRuntimeService.buildOrchestrator` | Uses `AssistantPersistenceMode.stagedCommit` but TurnLoop owns writes on the agent-loop path |

Reference: `Core/AgentRuntime/ARCHITECTURAL_EVALUATION.md` — legacy orchestrator loop removed; TurnLoop is the single path.

## What was proven

1. **Tool-call fragments stream incrementally** — `TurnLoop.publishStreamDelta` publishes `.toolCall(toolName:toolCallId:argumentsFragment:blockIndex:)` for each streaming fragment (`TurnLoop.swift:546-551`).
2. **Harness can parse partial args** — `MessageToolArgumentsParser` (added in spike) extracts visible text from incomplete JSON using regex + structural heuristics; covered by unit tests.
3. **Harness can suppress free-form text** — TurnLoop can gate `.text` deltas when `MessageOutputPolicy.messageToolOnly` is active on the turn configuration.
4. **Harness can rewrite committed assistant content** — After `AssistantMessageAccumulator.finalize()`, a post-processor can replace `Message.content` from the `message` tool call arguments before append.

## Free-form text rule (recommended)

When `MessageOutputPolicy.messageToolOnly` is active (default for channel trigger turns):

- **Streaming:** Do not publish `.text` deltas from the model as user-visible output. Publish `.text` derived from streaming `message` tool `argumentsFragment` instead.
- **Persistence:** If the assistant turn includes a `message` tool call, set `Message.content` from `MessagePresentation.textFallback()`. If the model emits bare prose with no `message` tool call, persist content as empty and keep prose in thinking/reasoning blocks only (not surfaced to channel surfaces).
- **Legacy surfaces:** Interactive transcript surfaces default to the `message` tool output verb. Opt out specific surfaces via `agentHarness.legacyStreamedTextSurfaces` in PromptConfig. Harness sends without explicit `originSurface` default to `"cli"` at the session boundary (with output-verb guidance when not opted out).

## Revised plan recommendation (Stage 2)

Proceed with Phases 1–8 as planned, harness-only:

1. **Phase 1** — `MessagePresentation`, `MessageToolProvider`, `describeMessageTool` schema merger, turn `MessageOutputPolicy` on channel origins.
2. **Phase 2** — `ChannelPlugin` capability record; migrate `MockChannelListener` to a thin plugin record.
3. **Phase 3** — `ChannelStreamingSurfaceSink` + wire isolated/threaded channel runs to block-streaming outbound.
4. **Phases 4–8** — Session grammar, lifecycle helpers, security consolidation, approval slot, config/tests.

No `phase0-kit-hook` work required.
