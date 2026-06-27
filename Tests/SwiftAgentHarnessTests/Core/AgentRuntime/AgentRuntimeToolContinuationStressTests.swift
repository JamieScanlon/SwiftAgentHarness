import Foundation
import Logging
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Agent runtime tool continuation stress", .serialized)
struct AgentRuntimeToolContinuationStressTests {
    @Test("single tool round-trip reaches final assistant across repeated harness runs", arguments: 1...30)
    func singleToolRoundTripStress(iteration: Int) async throws {
        let container = try section6StressContainer()
        let model = section6StressModel()
        let scriptedLLM = Section6StressScriptedToolThenAnswerLLM(
            toolName: ConversationsToolProvider.listConversationsToolName,
            toolCallID: "call_stress_\(iteration)",
            finalAssistantText: "Stress complete \(iteration)."
        )
        let manager = HarnessRuntimeSession(
            container: container,
            llmFactory: Section6StressScriptedLLMFactory(llm: scriptedLLM),
            harnessSessionPersistenceOverride: InMemoryHarnessSessionPersistence()
        )
        let publisher = Section6StressEventCapture()
        await manager.setConversationTopicPublisher(publisher)
        try await manager.createConversation(
            with: model,
            userSystemPrompt: "stress-\(iteration)",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        let conversationID = try #require(await manager.currentConversationID)

        let response = try await manager.sendMessageAndStreamResponse(
            "run stress tool \(iteration)",
            images: [],
            conversationID: conversationID
        )
        await manager.testing_awaitStreamingGenerationSettled(
            conversationID: response.conversationID,
            runID: response.runID,
            timeoutMS: 30_000
        )

        let streamCalls = await scriptedLLM.observedStreamCallCount()
        let lifecycle = await publisher.runtimeLifecycleEvents(for: conversationID)
        let iterationStarts = lifecycle.filter { $0.name == .loopIterationStarted }.count
        let modelCallsCompleted = lifecycle.filter { $0.name == .modelCallCompleted }.count
        let terminal = lifecycle.last(where: {
            $0.name == .turnCompleted || $0.name == .turnBounded || $0.name == .turnCancelled
        })

        let messages = try await waitForMessages(
            conversationID: conversationID,
            manager: manager,
            timeoutMS: 10_000
        ) { msgs in
            msgs.contains(where: { $0.role == .assistant && $0.content == "Stress complete \(iteration)." })
        }
        let registry = await manager.modelConversation(id: conversationID)
        let registryHasFinal = registry?.messages.contains(where: {
            $0.role == .assistant && $0.content == "Stress complete \(iteration)."
        }) == true
        let hasFinal = messages.contains(where: { $0.role == .assistant && $0.content == "Stress complete \(iteration)." })

        if !hasFinal {
            let registryRoles = registry?.messages.map(\.role.rawValue).joined(separator: ",") ?? "nil"
            let toolPolicies = await scriptedLLM.observedToolInvocationPolicyLabels().joined(separator: ",")
            Issue.record(
                "missing final assistant iteration=\(iteration) streamCalls=\(streamCalls) toolPolicies=\(toolPolicies) loopIterations=\(iterationStarts) modelCallsCompleted=\(modelCallsCompleted) registryCount=\(registry?.messages.count ?? -1) registryRoles=\(registryRoles) registryHasFinal=\(registryHasFinal) listedCount=\(messages.count) terminal=\(terminal?.name.rawValue ?? "nil") detail=\(terminal?.terminalReason?.detail ?? "nil") bounded=\(terminal?.terminalReason?.boundedReason?.rawValue ?? "nil")"
            )
        }

        #expect(streamCalls == 3)
        #expect(hasFinal)
    }
}

private actor Section6StressEventCapture: ConversationTopicPublishing {
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
        let _ = (runID, modelCallId)
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
}

private actor Section6StressScriptedToolThenAnswerLLM: LLMProtocol {
    private var streamCallCount: Int = 0
    private var observedToolInvocationPolicies: [String] = []
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
    nonisolated func getModelName() -> String { "stress-tool-then-answer" }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion, .tools] }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        return nextStreamResponse()
    }

    nonisolated func stream(
        _ messages: [Message],
        config: LLMRequestConfig
    ) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let policy = config.toolInvocationPolicy
        return AsyncThrowingStream { continuation in
            let producer = Task {
                await self.recordToolInvocationPolicy(policy)
                let value = await self.nextStreamResponse()
                continuation.yield(.complete(value))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    func observedStreamCallCount() -> Int { streamCallCount }

    func observedToolInvocationPolicyLabels() -> [String] {
        observedToolInvocationPolicies
    }

    private func recordToolInvocationPolicy(_ policy: ToolInvocationPolicy) {
        observedToolInvocationPolicies.append(String(describing: policy))
    }

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

private struct Section6StressScriptedLLMFactory: ModelLLMFactoring {
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

private func section6StressContainer() throws -> ModelContainer {
    let schema = HarnessPersistenceSchema.latest
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: config)
}

private func waitForMessages(
    conversationID: UUID,
    manager: HarnessRuntimeSession,
    timeoutMS: Int,
    predicate: @escaping ([Message]) -> Bool
) async throws -> [Message] {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
    while Date() < deadline {
        let messages = (try? await manager.listMessages(conversationID: conversationID)) ?? []
        if predicate(messages) { return messages }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return try await manager.listMessages(conversationID: conversationID)
}

private func section6StressModel() -> Model {
    Model(
        protocol: .openAIAPI,
        modelName: "section6-stress-model",
        serverURL: URL(string: "http://localhost:1234")!,
        capabilities: [.completion, .tools],
        modelProtocol: .openAIAPI
    )
}
