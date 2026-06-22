import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ContextProjectionService")
struct ContextProjectionServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeDependencies(container: ModelContainer) -> ConversationRuntimeDependencies {
        let stack = ConversationPersistenceStack.makeForTesting(container: container, logger: nil)
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: .default
        )
        return ConversationRuntimeDependencies(
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
    }

    private func makeService(
        deps: ConversationRuntimeDependencies,
        lastPromptTokens: Int? = 900,
        lastContextLimitTokens: Int? = 8_192
    ) async -> ContextProjectionService {
        let services = HarnessRuntimeSessionFactory.makeForTesting(deps: deps)
        if let lastPromptTokens {
            await services.agentRuntimeSessionService.testing_setLastPromptTokens(lastPromptTokens)
        }
        if let lastContextLimitTokens {
            await services.agentRuntimeSessionService.testing_setLastContextLimitTokens(lastContextLimitTokens)
        }
        return services.contextProjectionService
    }

    private func sampleConversation(modelLimit: Int? = 32_768) -> ModelConversation {
        let model = Model(
            protocol: .openAIAPI,
            modelName: "test",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: modelLimit
        )
        return ModelConversation(
            model: model,
            messages: [],
            systemPrompt: "s",
            interactionMode: .chat
        )
    }

    @Test("contextCompactionGatingResponse uses token snapshots and compaction config")
    func contextCompactionGatingViaService() async throws {
        let container = try makeContainer()
        let deps = makeDependencies(container: container)
        let service = await makeService(deps: deps)
        let conversation = sampleConversation(modelLimit: 8_192)

        let gating = await service.contextCompactionGatingResponse(for: conversation)
        let config = deps.conversationTransformConfiguration.contextCompaction
        let expectedThreshold = ContextCompactionPolicy.proactiveThresholdTokens(
            modelContextLimitTokens: 8_192,
            config: config
        )

        #expect(gating.proactiveThresholdTokens == expectedThreshold)
        #expect(gating.modelContextLimitTokens == 8_192)
        #expect(gating.charactersPerToken == config.charactersPerToken)
        #expect(gating.enableContextTransform == true)
        #expect(gating.contextCompactionConfigEnabled == config.enabled)
    }

    @Test("shouldEnableContextTransform respects compaction level off")
    func shouldEnableContextTransformOff() {
        var config = ConversationTransformConfiguration.default
        #expect(
            ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .chat,
                contextCompactionLevel: "off",
                transformConfiguration: config
            ) == false
        )
    }

    @Test("shouldEnableContextTransform enables shallow and full levels")
    func shouldEnableContextTransformShallowFull() {
        let config = ConversationTransformConfiguration.default
        #expect(
            ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .chat,
                contextCompactionLevel: "shallow",
                transformConfiguration: config
            ) == true
        )
        #expect(
            ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .chat,
                contextCompactionLevel: "full",
                transformConfiguration: config
            ) == true
        )
    }

    @Test("makeProjectionContext records transform snapshot provenance")
    func transformSnapshotRoundTrip() async throws {
        let container = try makeContainer()
        let deps = makeDependencies(container: container)
        let service = await makeService(deps: deps, lastPromptTokens: nil, lastContextLimitTokens: nil)
        let conversation = sampleConversation()
        let original = Message(id: UUID(), role: .user, content: "hi", timestamp: Date())
        let transformed = Message(id: UUID(), role: .user, content: "hello", timestamp: Date())
        let output = ContextTransformOutput(
            messages: [transformed],
            diagnostics: "ok",
            messageProvenance: [
                ContextTransformMessageProvenance(
                    transformedMessageID: transformed.id,
                    origin: .synthesized,
                    sourceMessageIDs: [original.id]
                ),
            ]
        )
        await service.recordContextTransformSnapshot(
            conversation: conversation,
            phase: .initial,
            originalMessages: [original],
            output: output
        )
        let resolved = await service.originalMessagesForTransformedContextMessage(
            conversationID: conversation.id,
            transformedMessageID: transformed.id
        )
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == original.id)
    }

    @Test("transformedContextMessages opens circuit after consecutive low-savings compactions")
    func projectionServiceOpensCircuitAfterLowSavings() async throws {
        let (service, counter, conversation) = try await makeLowSavingsProjectionService()
        let messages = longCompactionThread()
        let forcedGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        for _ in 0..<3 {
            _ = await service.transformedContextMessages(
                from: messages,
                conversation: conversation,
                phase: .initial,
                gatingOverride: forcedGating
            )
        }
        let beforeCircuit = await counter.callCount
        #expect(beforeCircuit == 3)
        _ = await service.transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil
        )
        let afterCircuit = await counter.callCount
        #expect(afterCircuit == 3)
    }

    @Test("forcedReactiveRetry bypasses open low-savings circuit")
    func forcedReactiveRetryBypassesOpenLowSavingsCircuit() async throws {
        let (service, counter, conversation) = try await makeLowSavingsProjectionService()
        let messages = longCompactionThread()
        let forcedGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        for _ in 0..<3 {
            _ = await service.transformedContextMessages(
                from: messages,
                conversation: conversation,
                phase: .initial,
                gatingOverride: forcedGating
            )
        }
        #expect(await counter.callCount == 3)
        _ = await service.transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: .forcedReactiveRetry
        )
        #expect(await counter.callCount == 4)
    }

    @Test("slashCommand manual compaction does not feed auto low-savings breaker")
    func slashCommandManualCompactionDoesNotFeedAutoLowSavingsBreaker() async throws {
        let container = try makeContainer()
        let counter = LowSavingsTransformCounter()
        var transformConfig = ConversationTransformConfiguration.default
        transformConfig.contextCompaction.compactionCircuitBreakerMaxFailures = 3
        transformConfig.contextCompaction.compactionMinPromptTokenSavingsFraction = 0.5
        transformConfig.contextCompaction.middleMinCharactersForCompactionLLM = 0
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = Model(
            protocol: .openAIAPI,
            modelName: "manual-breaker",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 2_500
        )
        let conversation = try await domain.createConversation(
            with: model,
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.routingAppendMessageJournalEntries(
            conversationID: conversation.id,
            messages: longCompactionThread()
        )
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: transformConfig
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
            conversationTransformConfiguration: transformConfig,
            conversationTransformer: counter,
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
        let service = await makeService(
            deps: deps,
            lastPromptTokens: nil,
            lastContextLimitTokens: 2_500
        )
        let messages = longCompactionThread()
        let forcedGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        for _ in 0..<2 {
            _ = await service.transformedContextMessages(
                from: messages,
                conversation: conversation,
                phase: .initial,
                gatingOverride: forcedGating
            )
        }
        #expect(await counter.callCount == 2)
        _ = try await service.performManualCompaction(
            conversationID: conversation.id,
            trigger: .slashCommand,
            reason: "topic focus"
        )
        #expect(await counter.callCount == 3)
        _ = await service.transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: forcedGating
        )
        #expect(await counter.callCount == 4)
        _ = await service.transformedContextMessages(
            from: messages,
            conversation: conversation,
            phase: .initial,
            gatingOverride: nil
        )
        #expect(await counter.callCount == 4)
    }

    @Test("projectModelContextPreview returns projected messages without persisting checkpoints")
    func projectModelContextPreviewIsReadOnly() async throws {
        let container = try makeContainer()
        let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
        let model = Model(
            protocol: .openAIAPI,
            modelName: "preview",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 2_500
        )
        let conversation = try await domain.createConversation(
            with: model,
            userSystemPrompt: "s",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .chat
        )
        try await domain.routingAppendMessageJournalEntries(
            conversationID: conversation.id,
            messages: longCompactionThread()
        )
        var transformConfig = ConversationTransformConfiguration.default
        transformConfig.contextCompaction.middleMinCharactersForCompactionLLM = 0
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
            persistenceDomain: domain,
            conversationTransformConfiguration: transformConfig
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
            conversationTransformConfiguration: transformConfig,
            conversationTransformer: PreviewSummaryTransformer(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
            logger: nil
        )
        let service = await makeService(
            deps: deps,
            lastPromptTokens: 900,
            lastContextLimitTokens: 2_500
        )
        let forcedGating = ContextCompactionGatingOptions(ignoreTokenThreshold: true, forceRunCompactionLLM: true)
        let (eventsBefore, _) = await domain.loadConversationEventsWithFrontier(conversationID: conversation.id)
        let compactionEventsBefore = eventsBefore.filter {
            $0.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue
        }.count
        let preview = try await service.projectModelContextPreview(
            conversationID: conversation.id,
            gatingOverride: forcedGating
        )
        #expect(preview.transformFailed == false)
        #expect(preview.projectedMessages.map(\.id) != preview.originalMessages.map(\.id))
        #expect(preview.passthroughReason == nil)
        let (eventsAfter, _) = await domain.loadConversationEventsWithFrontier(conversationID: conversation.id)
        let compactionEventsAfter = eventsAfter.filter {
            $0.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue
        }.count
        #expect(compactionEventsAfter == compactionEventsBefore)
    }
}

private func makeLowSavingsProjectionService() async throws -> (
    ContextProjectionService,
    LowSavingsTransformCounter,
    ModelConversation
) {
    let schema = HarnessPersistenceSchema.latest
    let container = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let counter = LowSavingsTransformCounter()
    var transformConfig = ConversationTransformConfiguration.default
    transformConfig.contextCompaction.compactionCircuitBreakerMaxFailures = 3
    transformConfig.contextCompaction.compactionMinPromptTokenSavingsFraction = 0.5
    transformConfig.contextCompaction.middleMinCharactersForCompactionLLM = 0
    let domain = ConversationPersistenceDomain.makeForTesting(container: container, logger: nil)
    let compactionCoordinator = CompactionConcurrencyCoordinator()
    let contextAssemblyRuntime = ContextAssemblyRuntimeFacade(
        persistenceDomain: domain,
        conversationTransformConfiguration: transformConfig
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
        conversationTransformConfiguration: transformConfig,
        conversationTransformer: counter,
        registryEntryProvider: nil,
        rankedRegistryEntriesProvider: nil,
        delegateCostTracker: nil,
        runtimeExecutorFactory: AgentRuntimeExecutorFactories.defaultInternal,
        logger: nil
    )
    let services = HarnessRuntimeSessionFactory.makeForTesting(deps: deps)
    await services.agentRuntimeSessionService.testing_setLastContextLimitTokens(2_500)
    let conversation = ModelConversation(
        model: Model(
            protocol: .openAIAPI,
            modelName: "test",
            serverURL: URL(string: "http://localhost:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 2_500
        ),
        messages: [],
        systemPrompt: "s",
        interactionMode: .chat
    )
    return (services.contextProjectionService, counter, conversation)
}

private struct PreviewSummaryTransformer: ConversationTransforming {
    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        let summary = Message(
            id: UUID(),
            role: .assistant,
            content: "## Active Task\npreview summary",
            timestamp: Date(),
            toolCalls: []
        )
        let headCount = max(1, input.messages.count / 4)
        let tailCount = max(1, input.messages.count / 4)
        let head = Array(input.messages.prefix(headCount))
        let tail = Array(input.messages.suffix(tailCount))
        return ContextTransformOutput(
            messages: head + [summary] + tail,
            diagnostics: ContextCompactionTransformer.summarizedDiagnostic,
            messageProvenance: nil
        )
    }

    func transformToolResult(_ input: ToolResultTransformInput) async throws -> ToolResultTransformOutput {
        ToolResultTransformOutput(result: input.result, diagnostics: nil)
    }

    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        TurnSummaryTransformOutput(replacementTurnMessages: input.turnMessages, diagnostics: nil)
    }
}

private actor LowSavingsTransformCounter: ConversationTransforming {
    private(set) var callCount = 0

    func transformContext(_ input: ContextTransformInput) async throws -> ContextTransformOutput {
        callCount += 1
        return ContextTransformOutput(
            messages: input.messages,
            diagnostics: ContextCompactionTransformer.prunedDiagnostic,
            messageProvenance: nil
        )
    }

    func transformToolResult(_ input: ToolResultTransformInput) async throws -> ToolResultTransformOutput {
        ToolResultTransformOutput(result: input.result, diagnostics: nil)
    }

    func transformTurnSummary(_ input: TurnSummaryTransformInput) async throws -> TurnSummaryTransformOutput {
        TurnSummaryTransformOutput(replacementTurnMessages: input.turnMessages, diagnostics: nil)
    }
}

private func longCompactionThread() -> [Message] {
    var messages: [Message] = [
        Message(id: UUID(), role: .system, content: "sys", timestamp: Date(), toolCalls: []),
    ]
    let chunk = String(repeating: "x", count: 4_000)
    for idx in 0..<12 {
        messages.append(Message(id: UUID(), role: .user, content: "u\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
        messages.append(Message(id: UUID(), role: .assistant, content: "a\(idx)-\(chunk)", timestamp: Date(), toolCalls: []))
    }
    messages.append(Message(id: UUID(), role: .user, content: "latest", timestamp: Date(), toolCalls: []))
    return messages
}
