import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop active memory wiring")
struct TurnLoopActiveMemoryTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "turn-loop-memory",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("Iteration one prepends ephemeral active memory system message to model stream input")
    func iterationOnePrependsActiveMemory() async throws {
        let model = makeModel()
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "find grafana notes", timestamp: Date())],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let capture = TurnLoopStreamMessageCapture()
        let basePorts = TurnLoopTestPorts.make(state: state)
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { _, _ in MemoryContextFencer.fence("grafana dashboard summary") },
            prefetchFn: { _, _ in }
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in conv.model.id },
            streamLLM: { messages, _, _, _, _, _, _ in
                await capture.record(messages)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let ports = AgentLoopPorts(
            model: modelPort,
            context: basePorts.context,
            tools: basePorts.tools,
            conversation: basePorts.conversation,
            memory: memoryPort,
            agentHarness: basePorts.agentHarness,
            contextCompaction: basePorts.contextCompaction,
            modeRegistry: basePorts.modeRegistry,
            logger: basePorts.logger
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let streamed = await capture.messages()
        #expect(streamed.contains(where: { $0.content.contains("[Active Memory Recall]") }))
        #expect(streamed.contains(where: { $0.content.contains("grafana dashboard summary") }))
        let transcript = await state.snapshot().messages
        #expect(transcript.contains(where: { $0.content.contains("[Active Memory Recall]") }) == false)
    }
}

private actor TurnLoopStreamMessageCapture {
    private var streamed: [Message] = []

    func record(_ messages: [Message]) {
        streamed = messages
    }

    func messages() -> [Message] {
        streamed
    }
}
