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

    @Test("prose streams as text_delta under structuredPreferred policy")
    func proseStreamsUnderStructuredPreferred() async throws {
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
                    continuation.yield(.stream(LLMResponse(content: "bare prose streams", toolCalls: [])))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCallStarted(id: "call-1", name: MessageToolArgumentsParser.toolName, contentIndex: 0)
                    )))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(
                            id: "call-1",
                            name: nil,
                            argumentsFragment: #"{"blocks":[{"type":"text","text":"Hello"}]}"#
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
        #expect(recorded.contains(where: { if case .text("bare prose streams") = $0 { return true }; return false }))
        #expect(!recorded.contains(where: { if case .text("Hello") = $0 { return true }; return false }))
        #expect(recorded.contains(where: {
            if case .toolCallStarted(toolName: MessageToolArgumentsParser.toolName, toolCallId: "call-1", contentIndex: 0) = $0 {
                return true
            }
            return false
        }))
    }

    @Test("CLI surface streams prose without synthesizing message tool args")
    func cliProseStreamsWithoutToolArgSynthesis() async throws {
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
                    continuation.yield(.stream(LLMResponse(content: "cli prose", toolCalls: [])))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCallStarted(id: "call-1", name: MessageToolArgumentsParser.toolName, contentIndex: 0)
                    )))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(
                            id: "call-1",
                            name: nil,
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
        #expect(recorded.contains(where: { if case .text("cli prose") = $0 { return true }; return false }))
        #expect(!recorded.contains(where: { if case .text("cli visible") = $0 { return true }; return false }))
    }

    @Test("toolCallCompleted passes through without synthesizing text")
    func bufferedProviderToolCallPassThrough() async throws {
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
        let fullArguments = #"{"blocks":[{"type":"text","text":"buffered visible"}]}"#
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [.completed(messageToolResult)],
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCallStarted(id: "call-1", name: MessageToolArgumentsParser.toolName, contentIndex: 0)
                    )))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCallCompleted(
                            id: "call-1",
                            name: MessageToolArgumentsParser.toolName,
                            arguments: fullArguments
                        )
                    )))
                    continuation.yield(.complete(LLMResponse(
                        content: "",
                        toolCalls: [
                            ToolCall(
                                name: MessageToolArgumentsParser.toolName,
                                arguments: .object([:]),
                                id: "call-1"
                            )
                        ]
                    )))
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
            configuration: AgentRuntimeTurnConfiguration(originSurface: InteractiveSurfaceID.tui),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let recorded = await deltas.snapshot()
        #expect(!recorded.contains(where: { if case .text("buffered visible") = $0 { return true }; return false }))
        #expect(recorded.contains(where: {
            if case .toolCallCompleted(
                toolName: MessageToolArgumentsParser.toolName,
                toolCallId: "call-1",
                arguments: fullArguments,
                blockIndex: nil
            ) = $0 {
                return true
            }
            return false
        }))
    }

    @Test("prose and message tool call both emit appropriate deltas")
    func proseAndMessageToolBothEmitDeltas() async throws {
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
                    continuation.yield(.stream(LLMResponse(content: "intro prose", toolCalls: [])))
                    continuation.yield(.stream(LLMResponse.streamChunk(
                        "",
                        streamingFragment: .toolCall(
                            id: "call-1",
                            name: MessageToolArgumentsParser.toolName,
                            argumentsFragment: #"{"blocks":[{"type":"text","text":"structured"}]}"#
                        )
                    )))
                    continuation.yield(.complete(LLMResponse(content: "intro prose", toolCalls: [])))
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
            configuration: AgentRuntimeTurnConfiguration(originSurface: InteractiveSurfaceID.tui),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let recorded = await deltas.snapshot()
        #expect(recorded.contains(where: { if case .text("intro prose") = $0 { return true }; return false }))
        #expect(recorded.contains(where: {
            if case .toolCall(toolName: MessageToolArgumentsParser.toolName, toolCallId: "call-1", _, blockIndex: nil) = $0 {
                return true
            }
            return false
        }))
        #expect(!recorded.contains(where: { if case .text("structured") = $0 { return true }; return false }))
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
