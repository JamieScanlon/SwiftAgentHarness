import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop behavioral recovery")
struct TurnLoopBehavioralRecoveryTests {
    /// A model that does not advertise forced tool choice (toolChoiceModes defaults to `[.auto]`).
    private func unsupportedModel() -> Model {
        Model(
            protocol: .ollama,
            modelName: "qwen3.6:27b",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion, .tools],
            modelProtocol: .ollama
        )
    }

    private func thinkEntry() -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(
                name: TerminationToolProvider.thinkToolName,
                description: "think",
                parameters: [],
                type: .function
            ),
            source: .local,
            effectClass: .readOnly,
            parallelHint: .serialOnly
        )
    }

    @Test("unsupported-forcing model gets a synthetic think tool call injected during behavioral recovery")
    func behavioralRecoveryInjectsThink() async throws {
        let conversationID = UUID()
        let modeProfileID = "turn-loop-behavioral-recovery"
        let profile = ResolvedModeProfile(
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
                        rollbackStalledTurn: true,
                        maxAttempts: 3,
                        reminder: .escalating,
                        behavioralInjectAfterStalls: 1,
                        behavioralRecoveryTemperature: 0.15
                    )
                )
            )
        )
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: unsupportedModel(),
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .agent,
                modeProfileID: modeProfileID
            )
        )
        let recorder = TurnLoopTranscriptRecorder()
        let temperatureRecorder = TurnLoopTemperatureRecorder()
        let thinkResult = Message(
            id: UUID(),
            role: .tool,
            content: "Thinking checkpoint recorded.",
            timestamp: Date(),
            toolCalls: []
        )
        let ports = TurnLoopTestPorts.make(
            state: state,
            recorder: recorder,
            dispatchOutcomes: [.completed(thinkResult)],
            streamFactory: {
                // Model perpetually stalls with a text-only turn (no tool calls).
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "still thinking out loud", toolCalls: [])))
                    continuation.finish()
                }
            },
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: false,
                additionalProfiles: [profile]
            ),
            effectiveToolEntries: [thinkEntry()],
            temperatureRecorder: temperatureRecorder
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

        // Behavioral recovery should never force tool choice, should inject at least one `think`
        // tool call, and must still terminate via the bounded recovery cap.
        let conversation = await state.snapshot()
        let injectedThink = conversation.messages.contains { message in
            message.role == .assistant && message.toolCalls.contains { $0.name == TerminationToolProvider.thinkToolName }
        }
        #expect(injectedThink)
        let toolMessages = await recorder.appendedToolMessages()
        #expect(!toolMessages.isEmpty)
        #expect(terminal.category == .boundedStop)

        // The first (pre-stall) model call uses the default temperature (nil override); behavioral
        // recovery then nudges the temperature on subsequent calls.
        let temperatures = await temperatureRecorder.recordedTemperatures()
        #expect(temperatures.first == .some(nil))
        #expect(temperatures.contains(0.15))
    }

    @Test("think recovery appends approval-pending tool result when dispatch requires approval")
    func thinkRecoveryApprovalRequiredAppendsPendingToolResult() async throws {
        let conversationID = UUID()
        let modeProfileID = "turn-loop-behavioral-recovery-approval"
        let profile = ResolvedModeProfile(
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
                        rollbackStalledTurn: true,
                        maxAttempts: 3,
                        reminder: .escalating,
                        behavioralInjectAfterStalls: 1,
                        behavioralRecoveryTemperature: 0.15
                    )
                )
            )
        )
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: unsupportedModel(),
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .agent,
                modeProfileID: modeProfileID
            )
        )
        let recorder = TurnLoopTranscriptRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            recorder: recorder,
            dispatchOutcomes: [
                .approvalRequired(toolName: TerminationToolProvider.thinkToolName, toolCallID: nil),
            ],
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "still thinking out loud", toolCalls: [])))
                    continuation.finish()
                }
            },
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: false,
                additionalProfiles: [profile]
            ),
            effectiveToolEntries: [thinkEntry()]
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
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )

        let conversation = await state.snapshot()
        let thinkCallIDs = Set(
            conversation.messages
                .filter { $0.role == .assistant }
                .flatMap(\.toolCalls)
                .filter { $0.name == TerminationToolProvider.thinkToolName }
                .compactMap(\.id)
        )
        #expect(!thinkCallIDs.isEmpty)

        let toolMessages = await recorder.appendedToolMessages()
        #expect(!toolMessages.isEmpty)
        #expect(toolMessages.allSatisfy { $0.content == AgentLoopToolDispatch.approvalPendingToolResultContent })
        #expect(Set(toolMessages.compactMap(\.toolCallId)) == thinkCallIDs)
    }

    @Test("forced-capable model recovery does not apply a temperature nudge")
    func forcedRecoveryKeepsDefaultTemperature() async throws {
        let conversationID = UUID()
        let modeProfileID = "turn-loop-forced-recovery-temperature"
        let profile = ResolvedModeProfile(
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
                        maxAttempts: 2,
                        reminder: .off,
                        behavioralInjectAfterStalls: 1,
                        behavioralRecoveryTemperature: 0.15
                    )
                )
            )
        )
        let forcedModel = Model(
            protocol: .openAIAPI,
            modelName: "forced-capable",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            requestFeatures: ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .required]
            )
        )
        let state = TurnLoopConversationState(
            conversation: ModelConversation(
                id: conversationID,
                model: forcedModel,
                messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
                turns: [],
                interactionMode: .agent,
                modeProfileID: modeProfileID
            )
        )
        let temperatureRecorder = TurnLoopTemperatureRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.complete(LLMResponse(content: "bare turn", toolCalls: [])))
                    continuation.finish()
                }
            },
            modeRegistry: ModeRegistryTestSupport.makePort(
                seedingBuiltIns: false,
                additionalProfiles: [profile]
            ),
            effectiveToolEntries: [thinkEntry()],
            temperatureRecorder: temperatureRecorder
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
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        // Forced recovery enforces tool_choice at the provider, so no temperature override is applied.
        let temperatures = await temperatureRecorder.recordedTemperatures()
        #expect(temperatures.allSatisfy { $0 == nil })
    }
}
