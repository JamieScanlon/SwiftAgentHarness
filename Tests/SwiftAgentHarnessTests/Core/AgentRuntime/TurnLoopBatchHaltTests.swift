import EasyJSON
import Foundation
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import Testing
@testable import SwiftAgentHarness

@Suite("Turn loop: halting a batch after a failed native computer action")
struct TurnLoopBatchHaltTests {
    private func entry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .mutating,
            parallelHint: .serialOnly,
            policyTags: [.haltsBatchOnFailure]
        )
    }

    @Test("After a halting failure the rest of the batch is answered, not run")
    func halts() async throws {
        let model = Model(
            id: UUID(), protocol: .anthropic, modelName: "claude", serverURL: URL(string: "https://api.anthropic.com")!,
            capabilities: [.completion, .tools], modelProtocol: .anthropic
        )
        let conversation = ModelConversation(
            id: UUID(), model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [], interactionMode: .agent
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let recorder = TurnLoopTranscriptRecorder()
        let calls = ["a", "b", "c"].map { ToolCall(name: "left_click", arguments: .object([:]), id: $0) }
        let ports = TurnLoopTestPorts.make(
            state: state,
            recorder: recorder,
            assistantToolCalls: calls,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "a", content: "refused")),
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "b", content: "should not run")),
            ],
            effectiveToolEntries: [entry("left_click")],
            batchHaltedFn: { $0 == "a" }
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await TurnLoop(ports: ports).run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let tools = await recorder.appendedToolMessages()
        #expect(tools.map(\.toolCallId) == ["a", "b", "c"])
        #expect(tools.map(\.content) == ["refused", ComputerUseNativeToolset.haltText, ComputerUseNativeToolset.haltText])
    }

    @Test("A batch with halting tools is never dispatched in parallel")
    func serial() async {
        let snapshot = RuntimeToolTurnPolicySnapshot(
            availabilitySnapshots: [],
            effectiveEntries: [entry("left_click")],
            dispatchContract: .conservativeDefault
        )
        let calls = [ToolCallRequest(id: "a", name: "left_click", arguments: .object([:])), ToolCallRequest(id: "b", name: "left_click", arguments: .object([:]))]
        #expect(await AgentLoopToolDispatch.batchRequiresSerialFallback(calls: calls, snapshot: snapshot, configuration: AgentRuntimeTurnConfiguration()))
    }
}
