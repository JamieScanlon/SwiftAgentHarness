import Foundation
import SwiftData
import Testing
import SwiftAgentKit
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

private struct DetachedRunSpyExecutor: AgentRuntimeExecuting {
    let terminalReason = ConversationRunTerminalReason(category: .naturalStop, detail: "detached_spy_complete")

    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult {
        let _ = context
        return .completed(reason: terminalReason)
    }

    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution {
        let (events, continuation) = AsyncStream.makeStream(
            of: RuntimeLifecycleEventPayload.self,
            bufferingPolicy: .unbounded
        )
        let result = Task {
            continuation.finish()
            return AgentRuntimeRunResult.completed(reason: terminalReason)
        }
        return AgentRuntimeTurnExecution(events: events, result: result)
    }
}

private struct SlowDetachedRunExecutor: AgentRuntimeExecuting {
    func runTurn(_ context: AgentRuntimeRunContext) async -> AgentRuntimeRunResult {
        let _ = context
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return .completed(reason: ConversationRunTerminalReason(category: .naturalStop))
    }

    func executeTurn(_ context: AgentRuntimeRunContext) -> AgentRuntimeTurnExecution {
        let (events, continuation) = AsyncStream.makeStream(
            of: RuntimeLifecycleEventPayload.self,
            bufferingPolicy: .unbounded
        )
        let result = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            continuation.finish()
            return AgentRuntimeRunResult.completed(reason: ConversationRunTerminalReason(category: .naturalStop))
        }
        return AgentRuntimeTurnExecution(events: events, result: result)
    }
}

@Suite("Orchestrator pool binding", .serialized)
struct OrchestratorPoolBindingTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel(name: String) -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
    }

    private func makeSession(
        container: ModelContainer,
        runtimeExecutorFactory: @escaping AgentRuntimeExecutorFactory = AgentRuntimeExecutorFactories.defaultInternal
    ) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            runtimeExecutorFactory: runtimeExecutorFactory
        )
    }

    private func registerChildConversation(
        session: HarnessRuntimeSession,
        parentID: UUID,
        childModel: Model
    ) async throws -> ModelConversation {
        let childID = try await session.persistenceDomain.createIsolatedSubAgent(
            parentConversationID: parentID,
            selectedModel: childModel,
            userSystemPrompt: "child",
            topic: "child",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        ).id
        return try #require(await session.persistenceDomain.modelConversation(id: childID))
    }

    private func drainStreams(_ response: ChatStreamResponse) async {
        async let partialDrain: Void = {
            for await _ in response.partialContent {}
        }()
        async let stateDrain: Void = {
            for await _ in response.orchestrationState {}
        }()
        _ = await (partialDrain, stateDrain)
    }

    @Test("acquireOrchestrator leaves parent pool entry intact")
    func acquirePreservesParentEntry() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let parentModel = makeModel(name: "parent-qwen")
        let childModel = makeModel(name: "child-llama")
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        let child = try await registerChildConversation(session: session, parentID: parent.id, childModel: childModel)

        let acquisition = await session.orchestratorRuntimeService.acquireOrchestrator(
            conversation: child,
            model: childModel
        )
        #expect(acquisition != nil)
        if let acquisition {
            await session.orchestratorRuntimeService.releaseOrchestrator(acquisition.handle)
        }

        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id) != nil)
        #expect(await session.agentRuntimeSessionService.orchestrator(for: child.id) != nil)
    }

    @Test("child run preserves parent orchestrator binding")
    func bindingNonInterferenceLitmus() async throws {
        let container = try makeContainer()
        let session = makeSession(
            container: container,
            runtimeExecutorFactory: { _ in DetachedRunSpyExecutor() }
        )
        let parentModel = makeModel(name: "parent-qwen")
        let childModel = makeModel(name: "child-llama")
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        let child = try await registerChildConversation(session: session, parentID: parent.id, childModel: childModel)
        let clearCountBefore = await session.agentRuntimeSessionService.testing_currentClearBindingCallCount()

        let response = try await session.agentRuntimeSessionService.serviceRuntimeSendMessageAndStreamResponse(
            "recall query",
            images: [],
            conversationID: child.id,
            configuration: AgentRuntimeTurnConfiguration(enableTools: true)
        )
        await drainStreams(response)

        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id) != nil)
        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id)?.llm.getModelName() == parentModel.modelName)
        #expect(await session.agentRuntimeSessionService.testing_currentClearBindingCallCount() == clearCountBefore)
    }

    @Test("child run creates distinct orchestrator from parent")
    func concurrentConversationsDistinctInstances() async throws {
        let container = try makeContainer()
        let session = makeSession(
            container: container,
            runtimeExecutorFactory: { _ in DetachedRunSpyExecutor() }
        )
        let parentModel = makeModel(name: "parent-qwen")
        let childModel = makeModel(name: "child-llama")
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        let child = try await registerChildConversation(session: session, parentID: parent.id, childModel: childModel)

        let response = try await session.agentRuntimeSessionService.serviceRuntimeSendMessageAndStreamResponse(
            "nested task",
            images: [],
            conversationID: child.id,
            configuration: AgentRuntimeTurnConfiguration(enableTools: true)
        )
        await drainStreams(response)

        let parentOrch = await session.agentRuntimeSessionService.orchestrator(for: parent.id)
        let childOrch = await session.agentRuntimeSessionService.orchestrator(for: child.id)
        #expect(parentOrch != nil)
        #expect(childOrch != nil)
        #expect(parentOrch !== childOrch)
    }

    @Test("child release does not break parent tool registry")
    func sharedManagerSafety() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let parentModel = makeModel(name: "parent-qwen")
        let childModel = makeModel(name: "child-llama")
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        let parentOrchestrator = try #require(await session.agentRuntimeSessionService.orchestrator(for: parent.id))
        let child = try await registerChildConversation(session: session, parentID: parent.id, childModel: childModel)

        let acquisition = try #require(
            await session.orchestratorRuntimeService.acquireOrchestrator(
                conversation: child,
                model: childModel
            )
        )
        await session.orchestratorRuntimeService.releaseOrchestrator(acquisition.handle)

        let entries = await session.orchestratorRuntimeService.allToolRegistryEntriesForOrchestration(
            orchestrator: parentOrchestrator
        )
        #expect(Set(entries.map(\.name)).contains("list_conversations"))
        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id) != nil)
    }

    @Test("cancelSubAgentRun leaves parent generation task active")
    func cancellationIsolation() async throws {
        let container = try makeContainer()
        let session = makeSession(
            container: container,
            runtimeExecutorFactory: { _ in SlowDetachedRunExecutor() }
        )
        let parentModel = makeModel(name: "parent-qwen")
        let childModel = makeModel(name: "child-llama")
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        await session.agentRuntimeSessionService.testing_setActiveStreamingRun(conversationID: parent.id, runID: UUID())
        let parentBindingBefore = await session.sessionOrchestratorConversationID()
        let child = try await registerChildConversation(session: session, parentID: parent.id, childModel: childModel)

        let response = try await session.agentRuntimeSessionService.serviceRuntimeSendMessageAndStreamResponse(
            "slow child",
            images: [],
            conversationID: child.id,
            configuration: AgentRuntimeTurnConfiguration(enableTools: true)
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        let childRunID = try #require(response.runID)
        await session.agentRuntimeSessionService.cancelSubAgentRun(
            conversationID: child.id,
            runID: childRunID
        )
        await drainStreams(response)

        let lifecycle = await session.agentRuntimeSessionService.lifecycleSnapshot(for: parent.id)
        #expect(lifecycle.generationTask != nil)
        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id) != nil)
    }
}

@Suite("Active memory pool orchestrator acceptance", .serialized)
struct ActiveMemoryPoolOrchestratorTests {
    @Test("blocking recall child run preserves parent orchestrator binding")
    func recallChildRunPreservesParentBinding() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let session = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container),
            runtimeExecutorFactory: { _ in DetachedRunSpyExecutor() }
        )
        let parentModel = Model(
            protocol: .openAIAPI,
            modelName: "parent-qwen",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
        let recallModel = MemorySubAgentSpawnAdapter.activeMemoryModel(from: .default)
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: parentModel, activeConversation: parent)
        let bindingClearsBefore = await session.agentRuntimeSessionService.testing_currentClearBindingCallCount()

        let childID = try await session.persistenceDomain.createIsolatedSubAgent(
            parentConversationID: parent.id,
            selectedModel: recallModel,
            userSystemPrompt: ActiveMemoryPreReplyPrompts.systemPrompt(),
            topic: "memory-active-recall",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: "memory-active-recall"
        ).id

        let response = try await session.agentRuntimeSessionService.serviceRuntimeSendMessageAndStreamResponse(
            ActiveMemoryPreReplyPrompts.userPrompt(query: "grafana notes"),
            images: [],
            conversationID: childID,
            configuration: AgentRuntimeTurnConfiguration(enableTools: true)
        )
        async let partialDrain: Void = {
            for await _ in response.partialContent {}
        }()
        async let stateDrain: Void = {
            for await _ in response.orchestrationState {}
        }()
        _ = await (partialDrain, stateDrain)

        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id) != nil)
        #expect(await session.agentRuntimeSessionService.orchestrator(for: parent.id)?.llm.getModelName() == parentModel.modelName)
        #expect(await session.agentRuntimeSessionService.testing_currentClearBindingCallCount() == bindingClearsBefore)
    }
}
