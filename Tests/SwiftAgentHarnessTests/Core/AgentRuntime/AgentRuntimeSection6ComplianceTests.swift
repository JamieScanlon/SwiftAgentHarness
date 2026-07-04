#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private actor Section6ConversationEventCapture: ConversationTopicPublishing {
    private var records: [(conversationID: UUID, payload: ConversationTopicEventPayload)] = []

    func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        let _ = transcriptSequence
        records.append((conversationID, payload))
    }

    func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        let _ = runID
        let _ = modelCallId
        records.append((conversationID, payload))
    }

    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        records.append((conversationID, payload))
    }

    func runtimeLifecycleEvents(for conversationID: UUID) -> [RuntimeLifecycleEventPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return records
            .filter { $0.conversationID == conversationID && $0.payload.semanticKind == .runtimeLifecycle }
            .compactMap { _, payload in
                guard let json = payload.jsonUTF8, let data = json.data(using: .utf8) else { return nil }
                return try? decoder.decode(RuntimeLifecycleEventPayload.self, from: data)
            }
    }

    func messagesRefreshRoles(for conversationID: UUID) -> [[String]] {
        records
            .filter { $0.conversationID == conversationID && $0.payload.semanticKind == .messagesRefresh }
            .compactMap { _, payload in
                guard let json = payload.jsonUTF8,
                      let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else {
                    return nil
                }
                if let messages = root as? [[String: Any]] {
                    return messages.compactMap { $0["role"] as? String }
                }
                if let object = root as? [String: Any],
                   let messages = object["messages"] as? [[String: Any]] {
                    return messages.compactMap { $0["role"] as? String }
                }
                return nil
            }
    }

    func messagesRefreshToolCallIDs(for conversationID: UUID) -> [[String]] {
        records
            .filter { $0.conversationID == conversationID && $0.payload.semanticKind == .messagesRefresh }
            .compactMap { _, payload in
                guard let json = payload.jsonUTF8,
                      let data = json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                else {
                    return nil
                }
                let messages: [[String: Any]]
                if let direct = root as? [[String: Any]] {
                    messages = direct
                } else if let object = root as? [String: Any],
                          let wrapped = object["messages"] as? [[String: Any]] {
                    messages = wrapped
                } else {
                    return nil
                }
                return messages.compactMap { message in
                    if let toolCallID = message["toolCallId"] as? String {
                        return toolCallID
                    }
                    if let toolCallID = message["toolCallID"] as? String {
                        return toolCallID
                    }
                    return nil
                }
            }
    }
}

private actor ScriptedStreamingLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let modelName: String
    private let chunks: [String]
    private let finalContent: String
    private let chunkDelayNanos: UInt64
    private let finalDelayNanos: UInt64

    init(
        modelName: String,
        chunks: [String],
        finalContent: String,
        chunkDelayNanos: UInt64 = 20_000_000,
        finalDelayNanos: UInt64 = 20_000_000
    ) {
        self.modelName = modelName
        self.chunks = chunks
        self.finalContent = finalContent
        self.chunkDelayNanos = chunkDelayNanos
        self.finalDelayNanos = finalDelayNanos
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { modelName }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        defer { streamCallCount += 1 }
        if streamCallCount == 0 {
            return MessageOutputTestSupport.messageToolLLMResponse(text: finalContent)
        }
        return MessageOutputTestSupport.emptyTurnStopLLMResponse()
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let callIndex = await self.claimStreamCall()
                    if callIndex > 0 {
                        continuation.yield(.complete(MessageOutputTestSupport.emptyTurnStopLLMResponse()))
                        continuation.finish()
                        return
                    }
                    for chunk in await self.chunks {
                        try Task.checkCancellation()
                        continuation.yield(.stream(LLMResponse(content: chunk, toolCalls: [])))
                        try await Task.sleep(nanoseconds: await self.chunkDelayNanos)
                        try Task.checkCancellation()
                    }
                    try await Task.sleep(nanoseconds: await self.finalDelayNanos)
                    try Task.checkCancellation()
                    let finalContent = await self.finalContent
                    continuation.yield(.complete(MessageOutputTestSupport.messageToolLLMResponse(text: finalContent)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private func claimStreamCall() -> Int {
        defer { streamCallCount += 1 }
        return streamCallCount
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor ScriptedToolThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let toolName: String
    private let toolCallID: String
    private let finalAssistantText: String

    init(toolName: String, toolCallID: String, finalAssistantText: String) {
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.finalAssistantText = finalAssistantText
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "tool-then-answer" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        return nextStreamResponse()
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return scriptedCompleteStream {
            await self.nextStreamResponse()
        }
    }

    func observedStreamCallCount() -> Int { streamCallCount }

    private func nextStreamResponse() -> LLMResponse {
        defer { streamCallCount += 1 }
        switch streamCallCount {
        case 0:
            let toolCall = ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)
            return LLMResponse(content: "", toolCalls: [toolCall])
        case 1:
            return MessageOutputTestSupport.messageToolLLMResponse(
                text: finalAssistantText,
                toolCallID: "call_message_2"
            )
        default:
            return MessageOutputTestSupport.emptyTurnStopLLMResponse()
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor ScriptedToolThenTimeoutLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let toolName: String
    private let toolCallID: String

    init(toolName: String, toolCallID: String) {
        self.toolName = toolName
        self.toolCallID = toolCallID
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "tool-then-timeout" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        if streamCallCount == 0 {
            let toolCall = ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)
            streamCallCount += 1
            return LLMResponse(content: "", toolCalls: [toolCall])
        }
        throw LLMError.timeout
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return scriptedCompleteStream {
            try await self.send([], config: LLMRequestConfig())
        }
    }

    func observedStreamCallCount() -> Int { streamCallCount }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor ScriptedToolThenDelayedAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let toolName: String
    private let toolCallID: String
    private let finalAssistantText: String
    private let secondCallDelayNanos: UInt64

    init(toolName: String, toolCallID: String, finalAssistantText: String, secondCallDelayNanos: UInt64) {
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.finalAssistantText = finalAssistantText
        self.secondCallDelayNanos = secondCallDelayNanos
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "tool-then-delayed-answer" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        return try await nextResponse()
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return scriptedCompleteStream {
            try await self.nextResponse()
        }
    }

    private func nextResponse() async throws -> LLMResponse {
        defer { streamCallCount += 1 }
        switch streamCallCount {
        case 0:
            let toolCall = ToolCall(name: toolName, arguments: .object([:]), id: toolCallID)
            return LLMResponse(content: "", toolCalls: [toolCall])
        case 1:
            try await Task.sleep(nanoseconds: secondCallDelayNanos)
            return MessageOutputTestSupport.messageToolLLMResponse(
                text: finalAssistantText,
                toolCallID: "call_message_2"
            )
        default:
            return MessageOutputTestSupport.emptyTurnStopLLMResponse()
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor ScriptedTwoToolsThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private let toolName: String
    private let firstToolCallID: String
    private let secondToolCallID: String
    private let finalAssistantText: String

    init(toolName: String, firstToolCallID: String, secondToolCallID: String, finalAssistantText: String) {
        self.toolName = toolName
        self.firstToolCallID = firstToolCallID
        self.secondToolCallID = secondToolCallID
        self.finalAssistantText = finalAssistantText
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "two-tools-then-answer" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        return nextStreamResponse()
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return scriptedCompleteStream {
            await self.nextStreamResponse()
        }
    }

    func observedStreamCallCount() -> Int { streamCallCount }

    private func nextStreamResponse() -> LLMResponse {
        defer { streamCallCount += 1 }
        switch streamCallCount {
        case 0:
            return LLMResponse(
                content: "",
                toolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: firstToolCallID)]
            )
        case 1:
            return LLMResponse(
                content: "",
                toolCalls: [ToolCall(name: toolName, arguments: .object([:]), id: secondToolCallID)]
            )
        case 2:
            return MessageOutputTestSupport.messageToolLLMResponse(
                text: finalAssistantText,
                toolCallID: "call_message_3"
            )
        default:
            return MessageOutputTestSupport.emptyTurnStopLLMResponse()
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private actor ScriptedEmptyAssistantLLM: LLMProtocol {
    private var streamCallCount: Int = 0

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { "empty-assistant" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        streamCallCount += 1
        return LLMResponse(content: "", toolCalls: [])
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return scriptedCompleteStream {
            await self.nextResponse()
        }
    }

    func observedStreamCallCount() -> Int { streamCallCount }

    private func nextResponse() -> LLMResponse {
        streamCallCount += 1
        return LLMResponse(content: "", toolCalls: [])
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.unsupportedCapability(.imageGeneration)
    }
}

private struct ScriptedLLMFactory: ModelLLMFactoring {
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

private func scriptedCompleteStream(
    response: @escaping @Sendable () async throws -> LLMResponse
) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
    AsyncThrowingStream { continuation in
        let producer = Task {
            do {
                let value = try await response()
                continuation.yield(.complete(value))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }
    }
}

private func section6Container() throws -> ModelContainer {
        return try HarnessTestModelContainer.makeInMemory()
}

private func section6Model() -> Model {
    Model(
        protocol: .openAIAPI,
        modelName: "section6-model",
        serverURL: URL(string: "http://localhost:1234")!,
        capabilities: [.completion, .tools],
        modelProtocol: .openAIAPI
    )
}

private func seedConversation(
    container: ModelContainer,
    model: Model,
    systemPrompt: String
) async throws -> UUID {
    let harness = InMemoryHarnessSessionPersistence()
    let host = HarnessRuntimeSession(
        container: container,
        harnessSessionPersistenceOverride: harness
    )
    try await host.createConversation(
        with: model,
        userSystemPrompt: systemPrompt,
        topic: nil,
        description: nil,
        metadata: nil,
        interactionMode: .chat
    )
    return try #require(await host.currentConversationID)
}

private func waitUntil(
    timeoutMS: Int = 4000,
    predicate: @escaping () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
}

private func expectListMessages(
    conversationID: UUID,
    manager: HarnessRuntimeSession,
    timeoutMS: Int = 45_000,
    predicate: @escaping ([Message]) -> Bool
) async throws {
    await waitUntil(timeoutMS: timeoutMS) {
        let messages = (try? await manager.listMessages(conversationID: conversationID)) ?? []
        return predicate(messages)
    }
    let messages = try await manager.listMessages(conversationID: conversationID)
    #expect(predicate(messages))
}

private func expectMessagesRefresh(
    conversationID: UUID,
    publisher: Section6ConversationEventCapture,
    baselineRoleSnapshotCount: Int,
    timeoutMS: Int = 20_000,
    predicate: @escaping ([[String]]) -> Bool
) async {
    await waitUntil(timeoutMS: timeoutMS) {
        let roles = await publisher.messagesRefreshRoles(for: conversationID)
        let newRoles = Array(roles.dropFirst(baselineRoleSnapshotCount))
        return predicate(newRoles)
    }
    let roles = await publisher.messagesRefreshRoles(for: conversationID)
    let newRoles = Array(roles.dropFirst(baselineRoleSnapshotCount))
    #expect(predicate(newRoles))
}

private func awaitStreamingRunSettled(
    _ manager: HarnessRuntimeSession,
    response: ChatStreamResponse,
    timeoutMS: Int = 30_000
) async {
    await manager.testing_awaitStreamingGenerationSettled(
        conversationID: response.conversationID,
        runID: response.runID,
        timeoutMS: timeoutMS
    )
}

private func drainChatStreamUnchecked(
    _ response: ChatStreamResponse
) async -> (partialText: String, states: [ConversationOrchestrationState]) {
    async let partial: String = {
        var combined = ""
        for await partial in response.partialContent {
            if case .text(let chunk) = partial {
                combined += chunk
            }
        }
        return combined
    }()
    async let states: [ConversationOrchestrationState] = {
        var values: [ConversationOrchestrationState] = []
        for await state in response.orchestrationState {
            values.append(state)
        }
        return values
    }()
    return await (partial, states)
}

private func drainChatStreamOrchestration(
    _ response: ChatStreamResponse,
    timeoutMS: Int = 5_000
) async -> [ConversationOrchestrationState] {
    await withCheckedContinuation { (continuation: CheckedContinuation<[ConversationOrchestrationState], Never>) in
        let gate = DrainResumeGate()
        Task {
            var values: [ConversationOrchestrationState] = []
            for await state in response.orchestrationState {
                values.append(state)
            }
            await gate.resumeOnce(returning: values, to: continuation)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMS) * 1_000_000)
            await gate.resumeOnce(returning: [], to: continuation)
        }
    }
}

private func drainChatStream(
    _ response: ChatStreamResponse,
    timeoutMS: Int = 5_000
) async -> (partialText: String, states: [ConversationOrchestrationState]) {
    await withCheckedContinuation { (continuation: CheckedContinuation<(String, [ConversationOrchestrationState]), Never>) in
        let gate = DrainResumeGate()
        Task {
            let drained = await drainChatStreamUnchecked(response)
            await gate.resumeOnce(returning: drained, to: continuation)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutMS) * 1_000_000)
            await gate.resumeOnce(returning: ("", []), to: continuation)
        }
    }
}

private actor DrainResumeGate {
    private var resumed = false

    func resumeOnce(
        returning value: (String, [ConversationOrchestrationState]),
        to continuation: CheckedContinuation<(String, [ConversationOrchestrationState]), Never>
    ) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }

    func resumeOnce(
        returning value: [ConversationOrchestrationState],
        to continuation: CheckedContinuation<[ConversationOrchestrationState], Never>
    ) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

@Suite("Agent Runtime section-6 verification", .serialized, .timeLimit(.minutes(2)))
struct AgentRuntimeSection6ComplianceTests {
    @Test("approval-required tools emit runtime lifecycle audit events")
    func approvalRequiredToolsEmitRuntimeLifecycleAudit() async throws {
        let container = try section6Container()
        let model = section6Model()
        let toolCallID = "call_approval_audit_1"
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [ConversationsToolProvider.listConversationsToolName],
                approvalTimeoutMilliseconds: 200
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(
                    toolName: ConversationsToolProvider.listConversationsToolName,
                    toolCallID: toolCallID,
                    finalAssistantText: "done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "approval-audit")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("trigger approval policy", images: [], conversationID: conversationID)
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let approvalRequired = lifecycle.first(where: {
            $0.name == .toolApprovalRequired && $0.toolName == ConversationsToolProvider.listConversationsToolName
        })
        #expect(approvalRequired != nil)
        #expect(approvalRequired?.approvalState == .pending)
        #expect(approvalRequired?.policyReason == ToolAvailabilityBlockReason.approvalRequired.rawValue)
        #expect(approvalRequired?.source == "runtime.toolDispatch")
        #expect(lifecycle.first?.name == .turnStarted)
        let terminalCount = lifecycle.filter {
            $0.name == .turnCompleted || $0.name == .turnCancelled || $0.name == .turnBounded
        }.count
        #expect(terminalCount == 1)

        let messages = try await manager.listMessages(conversationID: conversationID)
        let latestAssistant = try #require(messages.last(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }))
        for call in latestAssistant.toolCalls {
            let callID = try #require(call.id)
            #expect(messages.contains(where: { $0.role == .tool && $0.toolCallId == callID }))
        }
    }

    @Test("agent loop advertises approval-gated tools and surfaces lifecycle")
    func agentLoopApprovalGatedToolLifecycle() async throws {
        let container = try section6Container()
        let model = section6Model()
        let toolCallID = "call_legacy_approval_1"
        let manager = HarnessRuntimeSession(
            container: container,
            toolPolicy: ToolPolicyConfiguration(
                approvalRequiredToolNames: [ConversationsToolProvider.listConversationsToolName],
                approvalTimeoutMilliseconds: 200
            ),
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedToolThenAnswerLLM(
                    toolName: ConversationsToolProvider.listConversationsToolName,
                    toolCallID: toolCallID,
                    finalAssistantText: "approval done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "approval-audit")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "trigger approval policy",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let approvalRequired = lifecycle.first(where: {
            $0.name == .toolApprovalRequired
                && $0.toolName == ConversationsToolProvider.listConversationsToolName
        })
        #expect(approvalRequired != nil)
        #expect(approvalRequired?.approvalState == .pending)
        #expect(approvalRequired?.policyReason == ToolAvailabilityBlockReason.approvalRequired.rawValue)
        let terminalCount = lifecycle.filter {
            $0.name == .turnCompleted || $0.name == .turnCancelled || $0.name == .turnBounded
        }.count
        #expect(terminalCount == 1)

        let messages = try await manager.listMessages(conversationID: conversationID)
        let latestAssistant = try #require(messages.last(where: { $0.role == .assistant && !$0.toolCalls.isEmpty }))
        for call in latestAssistant.toolCalls {
            let callID = try #require(call.id)
            #expect(messages.contains(where: { $0.role == .tool && $0.toolCallId == callID }))
        }
    }

    @Test("dual-conversation concurrent streaming keeps assistant transcripts isolated")
    func dualConversationConcurrentStreamingIsolation() async throws {
        let container = try section6Container()
        let model = section6Model()
        let harness = InMemoryHarnessSessionPersistence()
        let publisher = Section6ConversationEventCapture()
        let manager1 = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "llm-one",
                    chunks: [],
                    finalContent: "assistant-one",
                    chunkDelayNanos: 30_000_000,
                    finalDelayNanos: 60_000_000
                )
            ),
            harnessSessionPersistenceOverride: harness
        )
        let manager2 = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "llm-two",
                    chunks: [],
                    finalContent: "assistant-two",
                    chunkDelayNanos: 30_000_000,
                    finalDelayNanos: 60_000_000
                )
            ),
            harnessSessionPersistenceOverride: harness
        )
        await manager1.setConversationTopicPublisher(publisher)
        await manager2.setConversationTopicPublisher(publisher)
        try await manager1.createConversation(with: model, userSystemPrompt: "sys-1", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationID1 = try #require(await manager1.currentConversationID)
        try await manager1.createConversation(with: model, userSystemPrompt: "sys-2", topic: nil, description: nil, metadata: nil, interactionMode: .chat)
        let conversationID2 = try #require(await manager1.currentConversationID)
        try await manager1.resetConversationsFromCatalog(availableModels: [model])
        try await manager2.resetConversationsFromCatalog(availableModels: [model])
        try await manager1.selectConversation(conversationID: conversationID1)
        try await manager2.selectConversation(conversationID: conversationID2)

        // Transcript-derived runs + runtime lifecycle envelopes are covered by other tests in this suite and ``RunLifecycleDurabilityTests`` (harness fixtures).

        async let response1 = manager1.sendMessageAndStreamResponse(
            "one",
            images: [],
            conversationID: conversationID1
        )
        async let response2 = manager2.sendMessageAndStreamResponse(
            "two",
            images: [],
            conversationID: conversationID2
        )
        let stream1 = try await response1
        let stream2 = try await response2
        async let settled1 = awaitStreamingRunSettled(manager1, response: stream1)
        async let settled2 = awaitStreamingRunSettled(manager2, response: stream2)
        await settled1
        await settled2

        await waitUntil(timeoutMS: 10_000) {
            let messages = (try? await manager1.listMessages(conversationID: conversationID1)) ?? []
            return messages.contains(where: { $0.role == .assistant && $0.content == "assistant-one" })
        }
        await waitUntil(timeoutMS: 10_000) {
            let messages = (try? await manager2.listMessages(conversationID: conversationID2)) ?? []
            return messages.contains(where: { $0.role == .assistant && $0.content == "assistant-two" })
        }

        let messages1 = try await manager1.listMessages(conversationID: conversationID1)
        let messages2 = try await manager2.listMessages(conversationID: conversationID2)
        #expect(messages1.contains(where: { $0.role == MessageRole.assistant && $0.content == "assistant-one" }))
        #expect(messages2.contains(where: { $0.role == MessageRole.assistant && $0.content == "assistant-two" }))
        #expect(!messages1.contains(where: { $0.content.contains("assistant-two") }))
        #expect(!messages2.contains(where: { $0.content.contains("assistant-one") }))
    }

    @Test("cancelled run persists interrupted partial assistant and cancellation marker")
    func cancelledRunPersistsInterruptedPartialAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "cancel-llm",
                    chunks: ["partial-a", "partial-b"],
                    finalContent: "assistant-final-should-not-persist",
                    chunkDelayNanos: 500_000_000,
                    finalDelayNanos: 500_000_000
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "cancel-test")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("cancel me", images: [], conversationID: conversationID)
        async let drainedTask = drainChatStreamOrchestration(response)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let runID = try #require(response.runID)
        try await manager.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)

        await waitUntil {
            let runs = await manager.listRunsForAPI(
                conversationID: conversationID,
                filter: ConversationRunListFilter(limit: 5)
            ).runs
            return runs.first(where: { $0.id == runID })?.outcome == .cancelled
        }

        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let cancelled = try #require(runs.first(where: { $0.id == runID }))
        #expect(cancelled.outcome == .cancelled)
        #expect(cancelled.cancellationReason?.contains("task_cancelled") == true)

        let messages = try await manager.listCurrentMessages()
        let partialAssistant = try #require(
            messages.first(where: { $0.role == MessageRole.assistant })
        )
        #expect(partialAssistant.content.contains("partial-a"))
        #expect(!partialAssistant.content.contains("assistant-final-should-not-persist"))

        let states = await drainedTask
        let finalState = states.last
        #expect(finalState?.harness?.terminationCategory == ConversationRunTerminalCategory.externalCancellation.rawValue)
        #expect(finalState?.harness?.terminationDetail == "task_cancelled")

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let terminalLifecycle = lifecycle.last(where: { $0.name == RuntimeLifecycleEventName.turnCancelled })
        #expect(terminalLifecycle != nil)
        #expect(terminalLifecycle?.terminalReason?.category == .externalCancellation)
    }

    @Test("runtime terminal lifecycle, runs projection, and harness termination stay in parity")
    func terminalParityAcrossRuntimeRestAndHarnessWire() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "parity-llm",
                    chunks: ["z"],
                    finalContent: "done",
                    chunkDelayNanos: 10_000_000,
                    finalDelayNanos: 10_000_000
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(with: model, userSystemPrompt: "parity")
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse("go", images: [], conversationID: conversationID)
        let states = await drainChatStreamOrchestration(response)
        let finalState = states.last
        let runID = try #require(response.runID)

        await waitUntil {
            let runs = await manager.listRunsForAPI(
                conversationID: conversationID,
                filter: ConversationRunListFilter(limit: 5)
            ).runs
            return runs.first(where: { $0.id == runID })?.outcome == .completed
        }

        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let run = try #require(runs.first(where: { $0.id == runID }))
        #expect(run.outcome == .completed)
        let terminal = await publisher.runtimeLifecycleEvents(for: conversationID)
            .last(where: { $0.name == RuntimeLifecycleEventName.turnCompleted })
        #expect(terminal?.terminalReason?.category == ConversationRunTerminalCategory.naturalStop)
        #expect(finalState?.harness?.terminationCategory == terminal?.terminalReason?.category.rawValue)
    }

    @Test("chat-mode tool call round-trip persists transcript and publishes messagesRefresh")
    func chatToolRoundTripPersistsAndPublishes() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_tool_roundtrip_1",
            finalAssistantText: "Tool run complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-tool-roundtrip",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)
        let refreshBaseline = await publisher.messagesRefreshRoles(for: conversationID).count

        let response = try await manager.sendMessageAndStreamResponse(
            "run the tool in chat mode",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)
        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Tool run complete." })
                && messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_tool_roundtrip_1" })
        }
        await manager.testing_refreshProjectedConversationMessages(conversationID: conversationID)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        #expect(lifecycle.contains(where: { $0.name == .modelCallCompleted }))
        #expect(lifecycle.contains(where: { $0.name == .turnCompleted }))

        await expectMessagesRefresh(
            conversationID: conversationID,
            publisher: publisher,
            baselineRoleSnapshotCount: refreshBaseline
        ) { newRoleSnapshots in
            newRoleSnapshots.contains(where: { $0.contains("tool") && $0.last == "assistant" })
        }
        let toolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        let newToolCallIDSnapshots = Array(toolCallIDSnapshots.dropFirst(refreshBaseline))
        #expect(newToolCallIDSnapshots.contains(where: { $0.contains("call_chat_tool_roundtrip_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() == 3)
    }

    @Test("chat-mode tool call round-trip commits assistant via agent loop transcript append")
    func chatToolRoundTripCommitsAssistantViaAgentLoop() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_agent_loop_1",
            finalAssistantText: "Agent loop transcript check."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-agent-loop",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run agent loop tool round trip",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Agent loop transcript check." })
        }
    }

    @Test("chat-mode revert tool round-trip publishes assistant in messagesRefresh")
    func chatRevertToolRoundTripPublishesAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let userAnchorID = UUID()
        let harness = InMemoryHarnessSessionPersistence()

        let scriptedLLM = ScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_revert_tool_roundtrip_1",
            finalAssistantText: "Revert tool run complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: harness
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-revert-tool-roundtrip",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)
        await manager.appendMessagesToConversation(
            [Message(id: userAnchorID, role: .user, content: "run the tool via revert", timestamp: Date(), toolCalls: [])],
            conversationID: conversationID
        )
        try await manager.selectConversation(conversationID: conversationID)

        let snapshotsBefore = await publisher.messagesRefreshRoles(for: conversationID).count
        let response = try await manager.revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: userAnchorID
        )
        await awaitStreamingRunSettled(manager, response: response)
        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Revert tool run complete." })
                && messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_revert_tool_roundtrip_1" })
        }

        let roleSnapshots = await publisher.messagesRefreshRoles(for: conversationID)
        let newRoleSnapshots = Array(roleSnapshots.dropFirst(snapshotsBefore))
        #expect(newRoleSnapshots.contains(where: { $0.contains("tool") && $0.last == "assistant" }))
        let toolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        let newToolCallIDSnapshots = Array(toolCallIDSnapshots.dropFirst(snapshotsBefore))
        #expect(newToolCallIDSnapshots.contains(where: { $0.contains("call_chat_revert_tool_roundtrip_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() == 3)
    }

    @Test("chat-mode tool timeout persists tool transcript and publishes terminal lifecycle")
    func chatToolTimeoutPersistsAndPublishesTerminal() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedToolThenTimeoutLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_chat_tool_timeout_1"
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6ConversationEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-tool-timeout",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run timeout tool in chat mode",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(conversationID: conversationID, manager: manager) { messages in
            messages.contains(where: { $0.role == .tool && $0.toolCallId == "call_chat_tool_timeout_1" })
        }
        let messages = try await manager.listMessages(conversationID: conversationID)
        let hasTimeoutAssistant = messages.contains { $0.role == .assistant && $0.content.contains("timeout") }
        #expect(hasTimeoutAssistant == false)

        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let terminalNames: Set<RuntimeLifecycleEventName> = [.turnCompleted, .turnCancelled, .turnBounded]
        #expect(lifecycle.contains(where: { terminalNames.contains($0.name) }))
        let terminal = lifecycle.last(where: { terminalNames.contains($0.name) })
        #expect(terminal?.terminalReason?.category == .failure)
        let terminalDetailHasTimeout = (terminal?.terminalReason?.detail ?? "")
            .localizedCaseInsensitiveContains("timeout")
        #expect(terminalDetailHasTimeout)

        let publishedRoleSnapshots = await publisher.messagesRefreshRoles(for: conversationID)
        #expect(publishedRoleSnapshots.contains(where: { $0.contains("tool") }))
        let publishedToolCallIDSnapshots = await publisher.messagesRefreshToolCallIDs(for: conversationID)
        #expect(publishedToolCallIDSnapshots.contains(where: { $0.contains("call_chat_tool_timeout_1") }))
        #expect(await scriptedLLM.observedStreamCallCount() >= 1)
    }

    @Test("chat-mode allows two tool rounds before final assistant response")
    func chatTwoToolRoundsReachFinalAssistant() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedTwoToolsThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            firstToolCallID: "call_chat_two_rounds_1",
            secondToolCallID: "call_chat_two_rounds_2",
            finalAssistantText: "Two rounds complete."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-two-rounds",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run two tool rounds",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)

        try await expectListMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { messages in
            messages.contains(where: { $0.role == .assistant && $0.content == "Two rounds complete." })
        }
        let messages = try await manager.listMessages(conversationID: conversationID)
        let hasFinalAssistant = messages.contains { message in
            message.role == .assistant && message.content == "Two rounds complete."
        }
        #expect(hasFinalAssistant)
        #expect(await scriptedLLM.observedStreamCallCount() == 4)
    }

    @Test("chat-mode zero transcript delta is classified in terminal detail")
    func chatZeroTranscriptDeltaClassification() async throws {
        let container = try section6Container()
        let model = section6Model()
        let scriptedLLM = ScriptedEmptyAssistantLLM()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "chat-zero-delta",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "return nothing",
            images: [],
            conversationID: conversationID
        )
        await awaitStreamingRunSettled(manager, response: response)
        let states = await drainChatStreamOrchestration(response)

        let messages = try await manager.listMessages(conversationID: conversationID)
        #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("without producing a final response") }) == false)

        let runID = try #require(response.runID)
        let runs = await manager.listRunsForAPI(
            conversationID: conversationID,
            filter: ConversationRunListFilter(limit: 5)
        ).runs
        let run = try #require(runs.first(where: { $0.id == runID }))
        #expect(run.outcome == .completed)
        #expect((states.last?.harness?.terminationDetail ?? "").contains("zero_transcript_delta"))
    }

    @Test("runtime streaming path persists memory snapshot with store version metadata")
    func runtimeStreamingPersistsVersionedMemorySnapshot() async throws {
        let container = try section6Container()
        let model = section6Model()
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: ScriptedLLMFactory(
                llm: ScriptedStreamingLLM(
                    modelName: "memory-snapshot-llm",
                    chunks: ["partial"],
                    finalContent: "done"
                )
            ),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "memory",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        let conversationID = try #require(await manager.currentConversationID)
        let response = try await manager.sendMessageAndStreamResponse("remember this", images: [], conversationID: conversationID)
        await awaitStreamingRunSettled(manager, response: response, timeoutMS: 15_000)

        let memoryKind = ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue
        let events = await HarnessConversationTestFixtures.journalEvents(
            host: manager,
            conversationID: conversationID,
            kind: memoryKind
        )
        if let latest = events.first,
           let wire = ConversationEventCodec.decode(MemoryInjectionSnapshotCheckpointWire.self, from: latest.payloadJSON) {
            #expect(wire.memoryStoreVersion != nil)
            #expect(!(wire.memoryEntryIDs ?? []).isEmpty)
        }
    }
}
