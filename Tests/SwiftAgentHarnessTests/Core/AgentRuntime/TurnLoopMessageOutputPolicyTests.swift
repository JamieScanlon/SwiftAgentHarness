import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop message output policy")
struct TurnLoopMessageOutputPolicyTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "message-output",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            requestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .none, .required, .specific]
            )
        )
    }

    @Test("messageToolOnly suppresses model text and streams message tool args")
    func messageToolOnlyStreaming() async throws {
        let conversationID = UUID()
        let model = makeModel()
        let userMessage = Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])
        let conversation = ModelConversation(
            id: conversationID,
            model: model,
            messages: [userMessage],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let deltas = TurnLoopDeltaRecorder()
        let messageToolResult = Message(
            id: UUID(),
            role: .tool,
            content: "delivered",
            timestamp: Date(),
            toolCalls: []
        )
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [.completed(messageToolResult)],
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.stream(LLMResponse(content: "bare prose should not stream", toolCalls: [])))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(
                            id: "call-1",
                            name: MessageToolArgumentsParser.toolName,
                            argumentsFragment: #"{"blocks":[{"type":"text","text":"visible"}]}"#
                        )
                    )))
                    continuation.yield(.complete(LLMResponse(content: "", toolCalls: [])))
                    continuation.finish()
                }
            },
            agentHarness: .default,
        )
        let loop = TurnLoop(ports: ports) { partial, _, _ in
            await deltas.record(partial)
        }
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: userMessage.id,
            configuration: AgentRuntimeTurnConfiguration(originSurface: InteractiveSurfaceID.tui),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let recorded = await deltas.snapshot()
        #expect(!recorded.contains(where: { if case .text("bare prose should not stream") = $0 { return true }; return false }))
        #expect(recorded.contains(where: { if case .text("visible") = $0 { return true }; return false }))
    }

    @Test("CLI surface uses messageToolOnly streaming path")
    func cliMessageToolOnlyStreaming() async throws {
        let conversationID = UUID()
        let model = makeModel()
        let userMessage = Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])
        let conversation = ModelConversation(
            id: conversationID,
            model: model,
            messages: [userMessage],
            turns: [],
            interactionMode: .chat
        )
        let state = TurnLoopConversationState(conversation: conversation)
        let deltas = TurnLoopDeltaRecorder()
        let messageToolResult = Message(
            id: UUID(),
            role: .tool,
            content: "delivered",
            timestamp: Date(),
            toolCalls: []
        )
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [.completed(messageToolResult)],
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.stream(LLMResponse(content: "bare prose should not stream", toolCalls: [])))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(
                            id: "call-1",
                            name: MessageToolArgumentsParser.toolName,
                            argumentsFragment: #"{"blocks":[{"type":"text","text":"cli visible"}]}"#
                        )
                    )))
                    continuation.yield(.complete(LLMResponse(content: "", toolCalls: [])))
                    continuation.finish()
                }
            },
            agentHarness: .default
        )
        let loop = TurnLoop(ports: ports) { partial, _, _ in
            await deltas.record(partial)
        }
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: userMessage.id,
            configuration: MessageOutputTurnConfiguration.forCLISend(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let recorded = await deltas.snapshot()
        #expect(!recorded.contains(where: { if case .text("bare prose should not stream") = $0 { return true }; return false }))
        #expect(recorded.contains(where: { if case .text("cli visible") = $0 { return true }; return false }))
    }
}

actor TurnLoopDeltaRecorder {
    private var items: [ChatStreamingPartial] = []

    func record(_ partial: ChatStreamingPartial) {
        items.append(partial)
    }

    func snapshot() -> [ChatStreamingPartial] {
        items
    }
}
