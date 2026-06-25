#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

private actor AgentRuntimeSeamRecorder {
    var runTurnCalls: Int = 0
    var executeTurnCalls: Int = 0

    func recordRunTurn() {
        runTurnCalls += 1
    }

    func recordExecuteTurn() {
        executeTurnCalls += 1
    }
}

private actor AgentRuntimeSeamEventCapture: ConversationTopicPublishing {
    private var payloads: [ConversationTopicEventPayload] = []

    func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        let _ = conversationID
        let _ = transcriptSequence
        payloads.append(payload)
    }

    func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        let _ = conversationID
        let _ = runID
        let _ = modelCallId
        payloads.append(payload)
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        let _ = conversationID
        payloads.append(payload)
    }

    func runtimeLifecycleNames() -> [RuntimeLifecycleEventName] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var names: [RuntimeLifecycleEventName] = []
        for payload in payloads where payload.semanticKind == .runtimeLifecycle {
            guard let json = payload.jsonUTF8, let data = json.data(using: .utf8) else { continue }
            guard let decoded = try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data) else { continue }
            names.append(decoded.name)
        }
        return names
    }

    func semanticKinds() -> [ConversationTopicEventPayload.SemanticKind] {
        payloads.map(\.semanticKind)
    }
}

private struct AgentRuntimeSeamSpy: AgentRuntimeExecuting {
    let recorder: AgentRuntimeSeamRecorder
    let terminalReason = ConversationRunTerminalReason(category: .naturalStop, detail: "spy_complete")

    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult {
        let _ = context
        await recorder.recordRunTurn()
        return .completed(reason: terminalReason)
    }

    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution {
        let (events, continuation) = AsyncStream.makeStream(
            of: RuntimeLifecycleEventPayload.self,
            bufferingPolicy: .unbounded
        )
        let result = Task {
            await recorder.recordExecuteTurn()
            let started = RuntimeLifecycleEventPayload(
                name: .turnStarted,
                conversationID: context.conversationID,
                runID: context.runID,
                source: "runtime-test"
            )
            continuation.yield(started)
            if let publish = context.runtimeLifecyclePublish {
                await publish(started)
            }

            let terminal = RuntimeLifecycleEventPayload(
                name: .turnCompleted,
                conversationID: context.conversationID,
                runID: context.runID,
                terminalReason: terminalReason,
                source: "runtime-test"
            )
            continuation.yield(terminal)
            if let publish = context.runtimeLifecyclePublish {
                await publish(terminal)
            }
            continuation.finish()
            return AgentRuntimeRunResult.completed(reason: terminalReason)
        }
        return AgentRuntimeTurnExecution(events: events, result: result)
    }
}

private actor RequestPurposeRecordingLLM: LLMProtocol {
    private var observedRequestPurposes: [String] = []

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "request-purpose-recorder" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = messages
        recordPurpose(from: config)
        return LLMResponse(content: "ok", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = messages
        return AsyncThrowingStream { continuation in
            Task {
                await self.recordPurpose(from: config)
                continuation.yield(.complete(LLMResponse(content: "ok", toolCalls: [])))
                continuation.finish()
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }

    func purposes() -> [String] {
        observedRequestPurposes
    }

    private func recordPurpose(from config: LLMRequestConfig) {
        guard let additional = config.additionalParameters,
              case .object(let object) = additional,
              case .string(let purpose)? = object["requestPurpose"] else {
            return
        }
        observedRequestPurposes.append(purpose)
    }
}

private struct RequestPurposeRecordingLLMFactory: ModelLLMFactoring {
    let llm: any LLMProtocol

    func makeBaseLLM(
        model: Model,
        providerBindings: [ProviderBinding]?,
        conversationID: UUID?,
        ownerAccountID: UUID?,
        systemPrompt: SystemPrompt,
        logger: Logger?,
        attemptObserver: (@Sendable (ModelCallAttemptObservation) async -> Void)?
    ) -> any LLMProtocol {
        let _ = (model, providerBindings, conversationID, ownerAccountID, systemPrompt, logger, attemptObserver)
        return llm
    }
}

@Suite("Agent Runtime seam and contract")
struct AgentRuntimeSeamTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "runtime-seam",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool, timeoutMS: Int = 3000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            if await predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    @Test("streaming task uses injected runtime executeTurn single terminal path")
    func injectedRuntimeExecutorDrivesStreamingTurn() async throws {
        let recorder = AgentRuntimeSeamRecorder()
        let runtime = AgentRuntimeSeamSpy(recorder: recorder)
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            runtimeExecutorFactory: { _ in runtime }
        )
        let publisher = AgentRuntimeSeamEventCapture()
        await manager.setConversationTopicPublisher(publisher)

        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let stream = try await manager.sendMessageAndStreamResponse("hello seam", images: [], conversationID: conversationID)
        let runID = try #require(stream.runID)
        // Keep parity with production clients that observe orchestration snapshots.
        _ = stream.orchestrationState

        await waitUntil({
            let runs = await manager.listRunsForAPI(
                conversationID: conversationID,
                filter: ConversationRunListFilter(limit: 5)
            ).runs
            return runs.first(where: { $0.id == runID })?.outcome == .completed
        })

        let executeCalls = await recorder.executeTurnCalls
        let runTurnCalls = await recorder.runTurnCalls
        #expect(executeCalls == 1)
        #expect(runTurnCalls == 0)
        let clearedConfig = await manager.agentRuntimeSessionService.activeTurnConfiguration(
            conversationID: conversationID,
            runID: runID
        )
        #expect(clearedConfig == nil)

        let names = await publisher.runtimeLifecycleNames()
        let startedCount = names.filter { $0 == .turnStarted }.count
        let terminalCount = names.filter { $0 == .turnCompleted || $0 == .turnCancelled || $0 == .turnBounded }.count
        #expect(startedCount == 1)
        #expect(terminalCount == 1)
        #expect(names == [.turnStarted, .turnCompleted])
    }

    @Test("projection refresh publishes messagesRefresh on conversation events topic")
    func projectionRefreshPublishesMessagesRefresh() async throws {
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = AgentRuntimeSeamEventCapture()
        await manager.setConversationTopicPublisher(publisher)

        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "projection-publish")
        let conversationID = try #require(await manager.currentConversationID)

        let assistantMessage = Message(
            id: UUID(),
            role: .assistant,
            content: "published over events",
            timestamp: Date(),
            toolCalls: []
        )
        await manager.testing_applyOrchestratorMessages([assistantMessage])

        let semanticKinds = await publisher.semanticKinds()
        #expect(semanticKinds.contains(ConversationTopicEventPayload.SemanticKind.messagesRefresh))
        let _ = conversationID
    }

    @Test("send path does not run turn metadata transform request purpose")
    func sendPathDoesNotRunTurnMetadataTransformPurpose() async throws {
        let recorder = RequestPurposeRecordingLLM()
        let runtime = AgentRuntimeSeamSpy(recorder: AgentRuntimeSeamRecorder())
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            llmFactory: RequestPurposeRecordingLLMFactory(llm: recorder),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence(),
            runtimeExecutorFactory: { _ in runtime }
        )

        let model = makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)
        _ = try await manager.sendMessageAndStreamResponse("kick off", images: [], conversationID: conversationID)

        let purposes = await recorder.purposes()
        #expect(purposes.contains("transform.conversationTurn.metadata") == false)
    }

    @Test("toolApprovalRequired emit populates load-bearing approval fields")
    func toolApprovalRequiredEmitPopulatesFields() async {
        actor PayloadCapture {
            var latest: RuntimeLifecycleEventPayload?
            func store(_ payload: RuntimeLifecycleEventPayload) { latest = payload }
            func value() -> RuntimeLifecycleEventPayload? { latest }
        }
        let conversationID = UUID()
        let runID = UUID()
        let modelID = UUID()
        let capture = PayloadCapture()
        let emitter = AgentRuntimeLifecycleEmitter { _, payload in
            await capture.store(payload)
        }
        await emitter.emit(
            .toolApprovalRequired(
                ToolApprovalRequiredInfo(
                    iteration: 2,
                    modelID: modelID,
                    toolName: "danger_tool",
                    toolCallID: "call-1",
                    route: .user,
                    title: "Approve",
                    description: "Needs approval",
                    severity: "high",
                    timeoutMs: 30_000,
                    timeoutBehavior: "deny",
                    resolutionKind: ToolApprovalResolutionKind.runtimeAuto.rawValue,
                    presentation: ApprovalPresentation.standard(title: "Approve", context: ["danger_tool"]),
                    source: "runtime.toolDispatch"
                )
            ),
            conversationID: conversationID,
            runID: runID
        )
        guard let payload = await capture.value() else {
            Issue.record("Expected lifecycle payload")
            return
        }
        #expect(payload.name == .toolApprovalRequired)
        #expect(payload.conversationID == conversationID)
        #expect(payload.runID == runID)
        #expect(payload.iteration == 2)
        #expect(payload.modelID == modelID)
        #expect(payload.toolName == "danger_tool")
        #expect(payload.toolCallID == "call-1")
        #expect(payload.approvalState == .pending)
        #expect(payload.approvalRoute == .user)
        #expect(payload.approvalTitle == "Approve")
        #expect(payload.approvalResolutionKind == ToolApprovalResolutionKind.runtimeAuto.rawValue)
    }
}
