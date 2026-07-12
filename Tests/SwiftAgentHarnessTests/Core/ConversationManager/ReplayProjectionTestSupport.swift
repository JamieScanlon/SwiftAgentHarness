import Foundation
import SwiftAgentKit
import SwiftData
@testable import SwiftAgentHarness

enum ReplayProjectionTestSupport {
    static func makeTestModel(name: String = "replay-projection-test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    static func makeReplayProjectionDependencies() throws -> (deps: ConversationRuntimeDependencies, container: ModelContainer) {
        let container = try HarnessTestModelContainer.makeInMemory()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: .default
        )
        let deps = ConversationRuntimeDependencies(
            persistenceDomain: domain,
            compactionCoordinator: compactionCoordinator,
            contextEngine: DefaultContextEngine(compactionCoordinator: compactionCoordinator, logger: nil),
            contextAssemblyRuntime: contextAssemblyRuntime,
            modeRegistry: ModeRegistryTestSupport.makePort(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            runtimeLaneCoordinator: RuntimeLaneCoordinator(configuration: .default),
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
        return (deps, container)
    }

    static func makeReplayProjectionServices(
        deps: ConversationRuntimeDependencies
    ) -> HarnessRuntimeSessionFactory.Services {
        HarnessRuntimeSessionFactory.makeForTesting(deps: deps)
    }

    @discardableResult
    static func seedConversation(
        deps: ConversationRuntimeDependencies,
        extraMessages: [Message],
        systemPrompt: String = "sys",
        interactionMode: InteractionMode = .chat
    ) async throws -> UUID {
        let model = makeTestModel()
        let conversation = try await deps.persistenceDomain.createConversation(
            with: model,
            userSystemPrompt: systemPrompt,
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: interactionMode
        )
        guard !extraMessages.isEmpty else { return conversation.id }
        guard var updated = await deps.persistenceDomain.modelConversation(id: conversation.id) else {
            throw ConversationServiceError.conversationNotFound
        }
        updated.messages.append(contentsOf: extraMessages)
        await deps.persistenceDomain.replaceConversationInRegistry(updated)
        return conversation.id
    }

    static func makeReplayService(
        deps: ConversationRuntimeDependencies,
        messaging: ConversationMessagingPort,
        services: HarnessRuntimeSessionFactory.Services
    ) -> ConversationReplayService {
        ConversationReplayService(
            deps: deps,
            contextProjection: services.contextProjectionService,
            selection: services.selection,
            sessionProjection: services.sessionProjection,
            messaging: messaging
        )
    }

    static func waitUntil(
        _ predicate: @escaping () async -> Bool,
        timeoutMS: Int = 2_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return false
    }
}

actor RecordingConversationMessagingPort: ConversationMessagingPort {
    private(set) var appendCalls: [(messages: [Message], conversationID: UUID)] = []
    private(set) var turnSummaryCalls: [UUID] = []
    private(set) var deleteCalls: [UUID] = []
    private(set) var refreshCalls: [(conversationID: UUID, baseMessagesOverride: [Message]?)] = []
    private(set) var toolTransformCalls: [(toolCall: ToolCall, result: ToolResult, conversationID: UUID?)] = []

    func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) async throws -> Message {
        message
    }

    func update(conversation: ModelConversation) async {}

    func appendMessagesToConversation(_ messages: [Message], conversationID: UUID) async {
        appendCalls.append((messages, conversationID))
    }

    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]?
    ) async throws {}

    func stripRunTailAfterAnchorIfNeeded(conversationID: UUID, anchorUserMessageID: UUID) async {}

    func refreshProjectedConversationMessages(conversationID: UUID, baseMessagesOverride: [Message]?) async {
        refreshCalls.append((conversationID, baseMessagesOverride))
    }

    func syncProjectionFromRegistry(conversationID: UUID) async {}

    func applyStreamingUserCancellation(conversationID: UUID) async {}

    func applySendFailure(_ error: Error, conversationID: UUID) async {}

    func waitUntilStreamingGenerationSettled(conversationID: UUID, runID: UUID?, timeoutMS: Int) async {}

    func resolveOrchestratorTargetConversationID() async -> UUID? { nil }

    func deleteConversation(conversationID: UUID) async throws {
        deleteCalls.append(conversationID)
    }

    func applyToolResultTransform(toolCall: ToolCall, result: ToolResult, conversationID: UUID?) async -> ToolResult {
        toolTransformCalls.append((toolCall, result, conversationID))
        return result
    }

    func applyTurnSummaryTransformIfNeeded(conversationID: UUID) async {
        turnSummaryCalls.append(conversationID)
    }

    func runtimeToolResultMiddlewarePipeline() async -> ToolResultMiddlewarePipeline {
        ToolResultMiddlewarePipeline(registrations: [])
    }

    func installTurnToolRegistryEntries(_ entries: [ToolRegistryEntry]) async {}

    func registerAgentToolResultMiddleware(_ middleware: AgentToolResultMiddleware) async {}

    func rollbackLatestAssistantTurnForRuntime(conversationID: UUID, assistantMessageID: UUID?) async {}

    func persistDelegateSpendSnapshot(conversationID: UUID) async {}
}
