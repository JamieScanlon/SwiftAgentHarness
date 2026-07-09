import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop provenance reminder")
struct TurnLoopProvenanceReminderTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "turn-loop-provenance",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("iteration one prepends ephemeral provenance system message outside user body")
    func iterationOnePrependsProvenanceReminder() async throws {
        let model = makeModel()
        let userMessage = Message(id: UUID(), role: .user, content: "external payload", timestamp: Date())
        let conversation = ModelConversation(
            id: UUID(),
            model: model,
            messages: [userMessage],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let capture = TurnLoopStreamMessageCapture()
        let basePorts = TurnLoopTestPorts.make(state: state)
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
            memory: basePorts.memory,
            agentHarness: basePorts.agentHarness,
            contextCompaction: basePorts.contextCompaction,
            modeRegistry: basePorts.modeRegistry,
            logger: basePorts.logger
        )
        let reminder = """
        [trigger-context]
        Trust level: user-deferred.
        [/trigger-context]
        """
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: userMessage.id,
            configuration: AgentRuntimeTurnConfiguration(ephemeralSystemReminder: reminder),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let streamed = await capture.messages()
        #expect(streamed.first?.role == .system)
        #expect(streamed.first?.content.contains(HarnessInjectedMessagePrefixes.triggerProvenance) == true)
        #expect(streamed.first?.content.contains("user-deferred") == true)
        #expect(streamed.contains(where: { $0.role == .user && $0.content == "external payload" }))
        let transcript = await state.snapshot().messages
        #expect(transcript.contains(where: { $0.content.contains("[trigger-context]") }) == false)
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
