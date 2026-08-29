import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

@Suite("TurnLoop gap fixes")
struct TurnLoopGapFixTests {
    private func makeModel(id: UUID = UUID()) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "turn-loop-gap",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    private func makeConversation(model: Model, interactionMode: InteractionMode = .chat) -> ModelConversation {
        ModelConversation(
            id: UUID(),
            model: model,
            messages: [Message(id: UUID(), role: .user, content: "go", timestamp: Date(), toolCalls: [])],
            turns: [],
            interactionMode: interactionMode
        )
    }

    private func contextWindowError() -> NSError {
        NSError(domain: "context window exceeded", code: 1)
    }

    @Test("disabled compaction config does not retry recoverable stream errors")
    func disabledCompactionConfigDoesNotRetry() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        var config = ContextCompactionConfiguration.default
        config.reactiveTriggerEnabled = false
        let ports = TurnLoopTestPorts.make(
            state: state,
            contextCompaction: config,
            streamFactory: {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: contextWindowError())
                }
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        await #expect(throws: (any Error).self) {
            _ = try await loop.run(
                conversationID: conversation.id,
                runID: UUID(),
                anchorUserMessageID: await state.anchorUserMessageID(),
                configuration: AgentRuntimeTurnConfiguration(),
                orchestrator: orchestrator,
                lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
            )
        }
    }

    @Test("default compaction config retries recoverable stream errors once")
    func defaultCompactionConfigRetriesOnce() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let attempts = StreamAttemptCounter()
        let compactionRecorder = TurnLoopCompactionRecorder()
        let ports = TurnLoopTestPorts.make(
            state: state,
            contextCompaction: .default,
            streamFactory: {
                await attempts.nextStream()
            },
            compactionRecorder: compactionRecorder
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(await attempts.count() == 2)
        let compactionHints = await compactionRecorder.recordedHints()
        #expect(compactionHints.count == 2)
        #expect(compactionHints[0] == .normal)
        #expect(compactionHints[1] == .forceCompaction)
    }

    @Test("compaction retry preserves ephemeral provenance reminder on retried model call")
    func compactionRetryPreservesProvenanceReminder() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let attempts = StreamAttemptCounter()
        let capture = TurnLoopStreamMessageCapture()
        let ports = makeCompactionRetryCapturePorts(
            state: state,
            capture: capture,
            attempts: attempts
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
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(ephemeralSystemReminder: reminder),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(await attempts.count() == 2)
        let streamed = await capture.messages()
        #expect(streamed.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.triggerProvenance) }))
        #expect(streamed.contains(where: { $0.content.contains("user-deferred") }))
    }

    @Test("compaction retry preserves active memory recall on retried model call")
    func compactionRetryPreservesActiveMemoryRecall() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let attempts = StreamAttemptCounter()
        let capture = TurnLoopStreamMessageCapture()
        let memoryPort = SessionRuntimeMemoryPort(
            recallFn: { _, _, _, _ in
                ActiveMemoryRecallOutcome(
                    note: MemoryContextFencer.fence("grafana dashboard summary"),
                    diagnostics: ActiveMemoryTurnDiagnostics(
                        status: .ok,
                        elapsedMs: 1,
                        queryMode: .recent,
                        summaryChars: 28,
                        note: "grafana dashboard summary",
                        skipReason: nil
                    )
                )
            },
            prefetchFn: { _, _, _, _ in }
        )
        let ports = makeCompactionRetryCapturePorts(
            state: state,
            capture: capture,
            attempts: attempts,
            memoryPort: memoryPort
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
        #expect(await attempts.count() == 2)
        let streamed = await capture.messages()
        #expect(streamed.contains(where: { $0.content.contains(HarnessInjectedMessagePrefixes.activeMemoryRecall) }))
        #expect(streamed.contains(where: { $0.content.contains("grafana dashboard summary") }))
    }

    @Test("compaction retry does not run when stream deltas were published")
    func compactionRetrySkippedWhenDeltasPublished() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model)
        let state = TurnLoopConversationState(conversation: conversation)
        let attempts = StreamAttemptCounter(includeDeltaBeforeError: true)
        let ports = TurnLoopTestPorts.make(
            state: state,
            contextCompaction: .default,
            streamFactory: {
                await attempts.nextStream()
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        await #expect(throws: (any Error).self) {
            _ = try await loop.run(
                conversationID: conversation.id,
                runID: UUID(),
                anchorUserMessageID: await state.anchorUserMessageID(),
                configuration: AgentRuntimeTurnConfiguration(),
                orchestrator: orchestrator,
                lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
            )
        }
        #expect(await attempts.count() == 1)
    }

    @Test("single tool round then answer appends final assistant")
    func singleToolRoundThenAnswerAppendsFinal() async throws {
        for iteration in 1...10 {
            try await runSingleToolRoundThenAnswerAppendsFinal(iteration: iteration)
        }
    }

    private func runSingleToolRoundThenAnswerAppendsFinal(iteration: Int) async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model, interactionMode: .chat)
        let state = TurnLoopConversationState(conversation: conversation)
        let streamScript = MultiRoundStreamScript(roundsWithToolCall: 1)
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "c1", content: "ok")),
            ],
            streamFactory: {
                await streamScript.nextStream()
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        let messages = await state.snapshot().messages
        #expect(await streamScript.observedStreamCount() == 2)
        #expect(messages.contains(where: { $0.role == .assistant && $0.content == "finished" }))
        let _ = iteration
    }

    @Test("ensure-bind is not repeated when model id is unchanged across iterations")
    func ensureBindSkippedWhenModelUnchanged() async throws {
        let model = makeModel()
        let conversation = makeConversation(model: model, interactionMode: .agent)
        let state = TurnLoopConversationState(conversation: conversation)
        let bindRecorder = EnsureBindRecorder(bootstrapModelID: model.id)
        let streamScript = MultiRoundStreamScript(roundsWithToolCall: 2)
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "c1", content: "ok")),
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "c2", content: "ok")),
            ],
            streamFactory: {
                await streamScript.nextStream()
            },
            ensureBoundFn: { conv, orchestrator in
                await bindRecorder.ensure(conversation: conv, orchestrator: orchestrator)
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(await bindRecorder.rebindCount() == 0)
        #expect(await streamScript.observedStreamCount() >= 3)
    }

    @Test("ensure-bind runs when conversation model id changes mid-loop")
    func ensureBindRunsWhenModelChanges() async throws {
        let initialModel = makeModel()
        let swappedModel = makeModel()
        let conversation = makeConversation(model: initialModel, interactionMode: .agent)
        let state = TurnLoopConversationState(conversation: conversation)
        let bindRecorder = EnsureBindRecorder(bootstrapModelID: initialModel.id)
        let streamScript = MultiRoundStreamScript(
            roundsWithToolCall: 2,
            swapModelAfterRound: 1,
            swappedModel: swappedModel,
            state: state
        )
        let ports = TurnLoopTestPorts.make(
            state: state,
            dispatchOutcomes: [
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "c1", content: "ok")),
                .completed(AgentLoopToolDispatch.toolResultMessage(toolCallId: "c2", content: "ok")),
            ],
            streamFactory: {
                await streamScript.nextStream()
            },
            ensureBoundFn: { conv, orchestrator in
                await bindRecorder.ensure(conversation: conv, orchestrator: orchestrator)
            }
        )
        let loop = TurnLoop(ports: ports)
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
        let _ = try await loop.run(
            conversationID: conversation.id,
            runID: UUID(),
            anchorUserMessageID: await state.anchorUserMessageID(),
            configuration: AgentRuntimeTurnConfiguration(),
            orchestrator: orchestrator,
            lifecycleEmitter: AgentRuntimeLifecycleEmitter { _, _ in }
        )
        #expect(await bindRecorder.rebindCount() == 1)
    }

    private func makeCompactionRetryCapturePorts(
        state: TurnLoopConversationState,
        capture: TurnLoopStreamMessageCapture,
        attempts: StreamAttemptCounter,
        memoryPort: SessionRuntimeMemoryPort? = nil
    ) -> AgentLoopPorts {
        let basePorts = TurnLoopTestPorts.make(
            state: state,
            contextCompaction: .default,
            streamFactory: { AsyncThrowingStream { $0.finish() } }
        )
        let modelPort = SessionRuntimeModelPort(
            ensureBoundFn: { conv, _ in conv.model.id },
            streamLLM: { messages, _, _, _, _, _, _ in
                await capture.record(messages)
                return await attempts.nextStream()
            }
        )
        return AgentLoopPorts(
            model: modelPort,
            context: basePorts.context,
            tools: basePorts.tools,
            conversation: basePorts.conversation,
            memory: memoryPort,
            agentHarness: basePorts.agentHarness,
            contextCompaction: basePorts.contextCompaction,
            modeRegistry: basePorts.modeRegistry,
            logger: basePorts.logger,
            settlementSink: basePorts.settlementSink
        )
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

private actor StreamAttemptCounter {
    private var streamCount = 0
    private let includeDeltaBeforeError: Bool

    init(includeDeltaBeforeError: Bool = false) {
        self.includeDeltaBeforeError = includeDeltaBeforeError
    }

    func nextStream() -> AsyncThrowingStream<ModelStreamEvent, Error> {
        streamCount += 1
        let attempt = streamCount
        return AsyncThrowingStream { continuation in
            if attempt == 1 {
                if includeDeltaBeforeError {
                    continuation.yield(.stream(LLMResponse(content: "partial", toolCalls: [])))
                }
                continuation.finish(throwing: NSError(domain: "context window exceeded", code: 1))
            } else {
                continuation.yield(.complete(LLMResponse(content: "done", toolCalls: [])))
                continuation.finish()
            }
        }
    }

    func count() -> Int { streamCount }
}

private actor EnsureBindRecorder {
    private var cachedID: UUID?
    private var rebindingCount = 0

    init(bootstrapModelID: UUID) {
        cachedID = bootstrapModelID
    }

    func ensure(conversation: ModelConversation, orchestrator: SwiftAgentKitOrchestrator) -> UUID {
        let _ = orchestrator
        if cachedID != conversation.model.id {
            rebindingCount += 1
            cachedID = conversation.model.id
        }
        return conversation.model.id
    }

    func rebindCount() -> Int { rebindingCount }
}

private actor MultiRoundStreamScript {
    private var streamCount = 0
    private let roundsWithToolCall: Int
    private let swapModelAfterRound: Int?
    private let swappedModel: Model?
    private let state: TurnLoopConversationState?

    init(
        roundsWithToolCall: Int,
        swapModelAfterRound: Int? = nil,
        swappedModel: Model? = nil,
        state: TurnLoopConversationState? = nil
    ) {
        self.roundsWithToolCall = roundsWithToolCall
        self.swapModelAfterRound = swapModelAfterRound
        self.swappedModel = swappedModel
        self.state = state
    }

    func nextStream() async -> AsyncThrowingStream<ModelStreamEvent, Error> {
        streamCount += 1
        let round = streamCount
        if let swapModelAfterRound, let swappedModel, let state, round == swapModelAfterRound + 1 {
            await state.swapModel(swappedModel)
        }
        let toolCalls: [ToolCall]
        if round <= roundsWithToolCall {
            toolCalls = [ToolCall(name: "tool", arguments: .object([:]), id: "c\(round)")]
        } else {
            toolCalls = []
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.complete(LLMResponse(content: round <= roundsWithToolCall ? "" : "finished", toolCalls: toolCalls)))
            continuation.finish()
        }
    }

    func observedStreamCount() -> Int { streamCount }
}
