import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop approval transcript")
struct TurnLoopApprovalTranscriptTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "turn-loop-approval",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("approval required appends synthetic tool results for gated and skipped calls")
    func approvalRequiredAppendsSyntheticToolResults() async throws {
        let conversationID = UUID()
        let model = makeModel()
        let modeProfileID = "turn-loop-stop-on-approval"
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: model,
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .agent,
                modeProfileID: modeProfileID
            )
        )
        let recorder = TurnLoopTranscriptRecorder()
        let lifecycle = TurnLoopLifecycleRecorder()
        let toolCalls = [
            ToolCall(name: "tool_a", arguments: .object([:]), id: "call-a"),
            ToolCall(name: "tool_b", arguments: .object([:]), id: "call-b"),
        ]
        let stopOnApprovalAgent = ResolvedModeProfile(
            id: modeProfileID,
            interactionMode: .agent,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: true,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            runtime: ModeProfileRuntimeSlice(stopOnApprovalRequest: true)
        )
        let ports = TurnLoopTestPorts.make(
            state: state,
            recorder: recorder,
            assistantToolCalls: toolCalls,
            dispatchOutcomes: [.approvalRequired(toolName: "tool_a", toolCallID: "call-a")],
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: false,
                additionalProfiles: [stopOnApprovalAgent]
            )
        )
        let loop = TurnLoop(ports: ports)
        let llm = StubTurnLoopLLM()
        let config = OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        let orchestrator = SwiftAgentKitOrchestrator(llm: llm, config: config)
        let _ = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(name: payload.name)
            }
        )
        let appended = await recorder.appendedToolMessages()
        #expect(appended.count == 2)
        #expect(appended.allSatisfy { $0.content == AgentLoopToolDispatch.approvalPendingToolResultContent })
        #expect(Set(appended.compactMap(\.toolCallId)) == Set(["call-a", "call-b"]))
        #expect(await lifecycle.completedToolCallCount() == 0)
        #expect(await lifecycle.startedToolCallCount() == 1)
        let order = await lifecycle.eventOrder()
        #expect(order.firstIndex(of: .toolCallStarted) != nil)
        #expect(order.firstIndex(of: .toolCallCompleted) == nil)
    }

    @Test("toolCallStarted emits before slow dispatch completes")
    func toolCallStartedBeforeSlowDispatchCompletes() async throws {
        let conversationID = UUID()
        let model = makeModel()
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: model,
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .chat
            )
        )
        let lifecycle = TurnLoopLifecycleRecorder()
        let slowGate = SlowDispatchGate()
        let toolCalls = [ToolCall(name: "slow_tool", arguments: .object([:]), id: "slow-call")]
        let ports = TurnLoopTestPorts.make(
            state: state,
            assistantToolCalls: toolCalls,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "slow-call", content: "ok")),
            ],
            slowDispatchGate: slowGate
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let runTask = Task {
            try await loop.run(
                conversationID: conversationID,
                runID: UUID(),
                anchorUserMessageID: await state.anchorUserMessageID(),
                configuration: AgentRuntimeTurnConfiguration(),
                orchestrator: orchestrator,
                lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                    await lifecycle.record(name: payload.name)
                }
            )
        }
        for _ in 0..<100 {
            if await slowGate.dispatchWasEntered() { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await slowGate.dispatchWasEntered())
        #expect(await lifecycle.startedToolCallCount() == 1)
        #expect(await lifecycle.completedToolCallCount() == 0)
        runTask.cancel()
        await slowGate.release()
        let _ = await runTask.result
        #expect(await lifecycle.startedToolCallCount() == 1)
    }
}
