import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop conformance")
struct TurnLoopConformanceTests {
    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "turn-loop-conformance",
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

    @Test("modelCallStarted emits after first stream event")
    func modelCallStartedAfterFirstStreamEvent() async throws {
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
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.stream(LLMResponse(content: "partial", toolCalls: [])))
                    continuation.yield(.complete(LLMResponse(content: "partial", toolCalls: [])))
                    continuation.finish()
                }
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        _ = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, payload in
                await lifecycle.record(name: payload.name)
            }
        )
        let order = await lifecycle.eventOrder()
        let iterationStarted = order.firstIndex(of: .loopIterationStarted)
        let modelStarted = order.firstIndex(of: .modelCallStarted)
        let modelCompleted = order.firstIndex(of: .modelCallCompleted)
        #expect(iterationStarted != nil)
        #expect(modelStarted != nil)
        #expect(modelCompleted != nil)
        if let iterationStarted, let modelStarted, let modelCompleted {
            #expect(iterationStarted < modelStarted)
            #expect(modelStarted < modelCompleted)
        }
    }

    @Test("required tool choice with no callable tools stops with bounded detail")
    func requiredToolChoiceUnsatisfiableStops() async throws {
        let conversationID = UUID()
        let model = makeModel()
        let modeProfileID = "turn-loop-required-empty-tools"
        let terminalToolProfile = ResolvedModeProfile(
            id: modeProfileID,
            interactionMode: .agent,
            assemblyKind: .agentBuild,
            allowsProactiveCompactionTriggers: true,
            appliesAgentBuildOrchestratorHarness: true,
            builtInSeedVersion: 0,
            semanticLayerTags: [],
            runtime: ModeProfileRuntimeSlice(
                termination: ModeProfileTerminationSlice(
                    policy: .terminalTool,
                    recovery: ModeProfileTerminationRecoverySlice(
                        strategy: .forcedToolChoice,
                        rollbackStalledTurn: false,
                        maxAttempts: 3,
                        reminder: .off
                    )
                )
            )
        )
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
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "bare assistant", toolCalls: [])))
                    continuation.finish()
                }
            },
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: false,
                additionalProfiles: [terminalToolProfile]
            )
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let terminal = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(terminal.category == .boundedStop)
        #expect(terminal.detail == "required_tool_choice_unsatisfiable")
    }

    @Test("bare-message natural stop stamps terminal finishReason on bare assistant")
    func bareMessageNaturalStopStampsFinishReason() async throws {
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
        let finishReasonRecorder = TurnLoopFinishReasonRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                    continuation.finish()
                }
            },
            finishReasonRecorder: finishReasonRecorder
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let terminal = try await loop.run(
            conversationID: conversationID,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(terminal.category == ConversationRunTerminalCategory.naturalStop)
        let stamps = await finishReasonRecorder.recordedStamps()
        #expect(stamps.count == 1)
        #expect(stamps[0].conversationID == conversationID)
        #expect(stamps[0].finishReason == "stop")
        let conversation = await state.snapshot()
        let assistant = try #require(conversation.messages.last(where: { $0.role == .assistant }))
        #expect(stamps[0].messageID == assistant.id)
    }
}
