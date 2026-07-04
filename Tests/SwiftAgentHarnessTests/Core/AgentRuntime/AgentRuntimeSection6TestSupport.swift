#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

actor Section6ConversationEventCapture: ConversationTopicPublishing {
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

actor ScriptedStreamingLLM: LLMProtocol {
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

actor ScriptedToolThenAnswerLLM: LLMProtocol {
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

actor ScriptedToolThenTimeoutLLM: LLMProtocol {
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

actor ScriptedToolThenDelayedAnswerLLM: LLMProtocol {
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

actor ScriptedTwoToolsThenAnswerLLM: LLMProtocol {
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

actor ScriptedEmptyAssistantLLM: LLMProtocol {
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

struct ScriptedLLMFactory: ModelLLMFactoring {
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

func scriptedCompleteStream(
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

func section6Container() throws -> ModelContainer {
        return try HarnessTestModelContainer.makeInMemory()
}

func section6Model() -> Model {
    Model(
        protocol: .openAIAPI,
        modelName: "section6-model",
        serverURL: URL(string: "http://localhost:1234")!,
        capabilities: [.completion, .tools],
        modelProtocol: .openAIAPI
    )
}

func seedConversation(
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

func waitUntil(
    timeoutMS: Int = 4000,
    predicate: @escaping () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
    while Date() < deadline {
        if await predicate() { return }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
}

func expectListMessages(
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

func expectMessagesRefresh(
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

func awaitStreamingRunSettled(
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

func drainChatStreamUnchecked(
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

func drainChatStreamOrchestration(
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

func drainChatStream(
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

actor DrainResumeGate {
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
