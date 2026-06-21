
import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

struct HarnessRuntimeHostFixture {
    let host: HarnessRuntimeSession
    let services: HarnessRuntimeSessionFactory.Services
    let local: LocalHarnessSessionPersistence
    let root: URL
    let stack: ConversationPersistenceStack
}

struct InMemoryHarnessRuntimeHostFixture {
    let host: HarnessRuntimeSession
    let domain: ConversationPersistenceDomain
    let stack: ConversationPersistenceStack
}

enum HarnessConversationTestFixtures {
    private final class ContainerHarnessBinding {
        weak var container: ModelContainer?
        let harness: InMemoryHarnessSessionPersistence

        init(container: ModelContainer, harness: InMemoryHarnessSessionPersistence) {
            self.container = container
            self.harness = harness
        }
    }

    /// One in-memory harness per live ``ModelContainer``. Prunes when the container deallocates so
    /// ``ObjectIdentifier`` reuse across tests cannot return another test's catalog.
    private final class SharedInMemoryHarnessRegistry: @unchecked Sendable {
        private var bindingsByContainerID: [ObjectIdentifier: ContainerHarnessBinding] = [:]
        private let lock = NSLock()

        func shared(for container: ModelContainer) -> InMemoryHarnessSessionPersistence {
            lock.lock()
            defer { lock.unlock() }
            pruneDeadBindings()
            let key = ObjectIdentifier(container)
            if let binding = bindingsByContainerID[key], binding.container === container {
                return binding.harness
            }
            let created = InMemoryHarnessSessionPersistence()
            bindingsByContainerID[key] = ContainerHarnessBinding(container: container, harness: created)
            return created
        }

        private func pruneDeadBindings() {
            bindingsByContainerID = bindingsByContainerID.filter { $0.value.container != nil }
        }
    }

    private static let sharedHarnessRegistry = SharedInMemoryHarnessRegistry()

    /// Stable in-memory catalog/transcript for tests that recreate ``ConversationManager`` / ``HarnessRuntimeSession`` with the same container.
    static func sharedInMemoryHarness(for container: ModelContainer) -> InMemoryHarnessSessionPersistence {
        sharedHarnessRegistry.shared(for: container)
    }

    static func makeRuntimeSession(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: sharedInMemoryHarness(for: container)
        )
    }

    static func makeServiceGraph(services: HarnessRuntimeSessionFactory.Services) -> HarnessServiceGraph {
        let subAgentIngress = SubAgentAPIIngressService(
            spawn: services.subAgentSpawnService,
            completion: services.subAgentCompletionRuntimeService
        )
        let runtimeGraph = SplitGatewayServiceFactory.makeRuntimeGraph(
            services: services,
            subAgentLifecycleHost: subAgentIngress,
            subAgentCompletionHost: subAgentIngress,
            subAgentCompletion: SubAgentCompletionIngressService(host: subAgentIngress)
        )
        return SplitGatewayServiceFactory.makeServiceGraph(runtimeGraph: runtimeGraph)
    }

    static func makeServiceGraph(from session: HarnessRuntimeSession) async -> HarnessServiceGraph {
        makeServiceGraph(services: await session.services)
    }

    static func attachSharedInMemoryHarness(to manager: ConversationManager, container: ModelContainer) {
        manager.setHarnessSessionPersistenceOverride(sharedInMemoryHarness(for: container))
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    static func createConversation(
        host: HarnessRuntimeSession,
        model: Model,
        userSystemPrompt: String,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode = .chat,
        modeProfileID: String? = nil
    ) async throws -> UUID {
        try await (await host.conversationDomainServices).controlPlane.createConversation(
            with: model,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID
        )
    }

    static func copyConversation(
        host: HarnessRuntimeSession,
        from sourceConversationID: UUID,
        to model: Model,
        systemPrompt: String
    ) async throws -> UUID {
        try await (await host.conversationDomainServices).lifecycle.copyConversation(
            from: sourceConversationID,
            to: model,
            systemPrompt: systemPrompt
        )
    }

    static func deleteConversation(host: HarnessRuntimeSession, conversationID: UUID, hard: Bool = true) async throws {
        try await (await host.conversationDomainServices).lifecycle.deleteConversation(conversationID: conversationID, hard: hard)
    }

    static func resetCatalog(host: HarnessRuntimeSession, availableModels: [Model]) async throws {
        try await (await host.conversationStartupService).resetConversationsFromCatalog(availableModels: availableModels)
    }

    static func makeTestModel(name: String = "fixture-model") -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            capabilities: [],
            modelProtocol: .openAIAPI
        )
    }

    static func makeLocalRoot(label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sha-fixture-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    static func makeLocalPersistence(root: URL) throws -> LocalHarnessSessionPersistence {
        try LocalHarnessSessionPersistence(root: root)
    }

    static func attachLocal(_ local: LocalHarnessSessionPersistence, to manager: ConversationManager) {
        manager.setHarnessSessionPersistenceOverride(local)
    }

    static func makeLocalPersistenceStack(
        label: String,
        logger: Logger? = nil
    ) throws -> (stack: ConversationPersistenceStack, local: LocalHarnessSessionPersistence, root: URL) {
        let root = makeLocalRoot(label: label)
        let local = try makeLocalPersistence(root: root)
        let container = try makeInMemoryContainer()
        let manager = ConversationManager(container: container, logger: logger)
        attachLocal(local, to: manager)
        let (eventLog, derived) = makeJournalPersistence(manager: manager)
        let stack = ConversationPersistenceStack(
            modelContainer: container,
            conversationManager: manager,
            eventLog: eventLog,
            derivedEventStore: derived
        )
        return (stack, local, root)
    }

    static func makeJournalPersistence(
        manager: ConversationManager
    ) -> (eventLog: ConversationEventLogService, derived: RoutingDerivedEventStore) {
        let harness = manager.harnessSessionPersistence
        return (
            ConversationEventLogService(harness: harness),
            RoutingDerivedEventStore(harness: harness)
        )
    }

    static func makeDerivedStore(container: ModelContainer) -> RoutingDerivedEventStore {
        RoutingDerivedEventStore(harness: sharedInMemoryHarness(for: container))
    }

    static func makeDerivedStore(
        container: ModelContainer,
        manager: ConversationManager
    ) -> RoutingDerivedEventStore {
        attachSharedInMemoryHarness(to: manager, container: container)
        return makeDerivedStore(container: container)
    }

    static func journalEvents(
        host: HarnessRuntimeSession,
        conversationID: UUID,
        kind: String? = nil,
        journalStream: ConversationJournalStream? = nil
    ) async -> [CachedConversationEvent] {
        await host.journalEvents(conversationID: conversationID, kind: kind, journalStream: journalStream)
    }

    static func journalEvents(
        manager: ConversationManager,
        conversationID: UUID,
        kind: String? = nil,
        journalStream: ConversationJournalStream? = nil
    ) -> [CachedConversationEvent] {
        let (events, _) = manager.loadConversationEventsWithFrontier(conversationID: conversationID)
        return events.filter { event in
            if let kind, event.kind != kind { return false }
            if let journalStream, event.journalStreamRaw != journalStream.rawValue { return false }
            return true
        }
        .sorted { $0.eventID < $1.eventID }
    }

    static func bootstrapInMemoryCatalogRow(
        manager: ConversationManager,
        conversationID: UUID,
        modelName: String = "journal-test"
    ) throws {
        guard let inMemory = manager.harnessSessionPersistence as? InMemoryHarnessSessionPersistence else { return }
        if try inMemory.catalogConversation(id: conversationID) != nil { return }
        var record = SessionCatalogRecord(
            id: conversationID,
            topic: nil,
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: modelName,
            interactionModeRaw: InteractionMode.chat.rawValue,
            modeProfileID: nil
        )
        record.agentId = SessionPersistenceLayout.defaultAgentId
        try inMemory.bootstrapEmptyConversation(record)
    }

    static func resetRegistryFromCatalog(manager: ConversationManager, availableModels: [Model]) throws {
        try manager.resetConversationsFromCatalog(availableModels: availableModels)
    }

    static func bootstrapEmptySession(
        local: LocalHarnessSessionPersistence,
        id: UUID,
        model: Model,
        topic: String
    ) throws {
        let record = SessionCatalogRecord(
            id: id,
            topic: topic,
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: model.modelName,
            interactionModeRaw: InteractionMode.chat.rawValue,
            modeProfileID: nil
        )
        try local.bootstrapEmptyConversation(record)
    }

    static func messageShapedTranscriptCount(
        local: LocalHarnessSessionPersistence,
        conversationID: UUID
    ) throws -> Int {
        let entries = try local.readTranscriptEntries(conversationID: conversationID, request: .full)
        return entries.filter { $0.type == .message || $0.type == .system }.count
    }

    static func makeHarnessRuntimeHost(
        label: String,
        logger: Logger? = nil
    ) throws -> HarnessRuntimeHostFixture {
        let (stack, local, root) = try makeLocalPersistenceStack(label: label)
        let domain = ConversationPersistenceDomain.makeForTesting(
            container: stack.modelContainer,
            logger: logger,
            harnessSessionPersistenceOverride: local
        )
        let compactionCoordinator = CompactionConcurrencyCoordinator()
        let contextEngine = DefaultContextEngine(compactionCoordinator: compactionCoordinator, logger: logger)
        let (host, services) = HarnessRuntimeSession.makeProduction(
            persistenceDomain: domain,
            logger: logger,
            toolPolicy: .unrestricted,
            trustPolicyConfiguration: .disabled,
            agentHarness: .default,
            thinkingPolicyConfiguration: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            llmFactory: StandardModelLLMFactory(),
            registryEntryProvider: nil,
            rankedRegistryEntriesProvider: nil,
            delegateCostTracker: nil,
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            compactionCoordinator: compactionCoordinator,
            contextEngine: contextEngine,
            modeRegistry: ModeRegistryTestSupport.makePort(),
            runtimeLaneConfiguration: .default,
            runtimeExecutorFactory: AgentRuntimeExecutorFactories.default
        )
        return HarnessRuntimeHostFixture(host: host, services: services, local: local, root: root, stack: stack)
    }

    static func makeInMemoryHarnessRuntimeHost(
        logger: Logger? = nil
    ) throws -> InMemoryHarnessRuntimeHostFixture {
        let container = try makeInMemoryContainer()
        let harness = sharedInMemoryHarness(for: container)
        let domain = ConversationPersistenceDomain.makeForTesting(
            container: container,
            logger: logger,
            harnessSessionPersistenceOverride: harness
        )
        let stack = ConversationPersistenceStack.makeForTesting(
            container: container,
            logger: logger,
            harnessSessionPersistenceOverride: harness
        )
        let host = HarnessRuntimeSession(
            persistenceDomain: domain,
            logger: logger,
            toolPolicy: .unrestricted,
            agentHarness: .default,
            conversationTransformConfiguration: .default,
            conversationTransformer: NoOpConversationTransformer(),
            llmFactory: StandardModelLLMFactory(),
            callScheduler: ModelCallScheduler(),
            invocationCoordinator: ModelInvocationCoordinator(),
            compactionCoordinator: CompactionConcurrencyCoordinator(),
            contextEngine: nil
        )
        return InMemoryHarnessRuntimeHostFixture(host: host, domain: domain, stack: stack)
    }

    @discardableResult
    static func seedRegistryConversation(
        host: HarnessRuntimeSession,
        model: Model,
        systemPrompt: String = "System",
        extraMessages: [Message] = [],
        topic: String? = nil,
        availableModels: [Model]? = nil
    ) async throws -> UUID {
        _ = try await createConversation(
            host: host,
            model: model,
            userSystemPrompt: systemPrompt,
            topic: topic
        )
        let id = try #require(await host.currentConversationID)
        if !extraMessages.isEmpty {
            try await host.selectConversation(conversationID: id)
            await host.testing_applyOrchestratorMessages(extraMessages)
        }
        try await resetCatalog(host: host, availableModels: availableModels ?? [model])
        return id
    }

    @discardableResult
    static func seedRegistryConversationWithStaggeredMessages(
        host: HarnessRuntimeSession,
        model: Model,
        availableModels: [Model]? = nil
    ) async throws -> UUID {
        let base = Date().addingTimeInterval(-100)
        let user = Message(id: UUID(), role: .user, content: "User", timestamp: base.addingTimeInterval(1), toolCalls: [])
        let assistant = Message(
            id: UUID(),
            role: .assistant,
            content: "Assistant",
            timestamp: base.addingTimeInterval(2),
            toolCalls: [ToolCall(name: "some_tool", arguments: .object([:]), id: "tc-1")]
        )
        let tool = Message(
            id: UUID(),
            role: .tool,
            content: "Tool",
            timestamp: base.addingTimeInterval(3),
            toolCalls: [],
            toolCallId: "tc-1"
        )
        return try await seedRegistryConversation(
            host: host,
            model: model,
            systemPrompt: "System",
            extraMessages: [user, assistant, tool],
            availableModels: availableModels
        )
    }

    static func seedTwoDistinctRegistryConversations(
        host: HarnessRuntimeSession,
        model: Model,
        userContentA: String = "UserA-only",
        userContentB: String = "UserB-only",
        systemPromptA: String = "SysA",
        systemPromptB: String = "SysB",
        availableModels: [Model]? = nil
    ) async throws -> (idA: UUID, idB: UUID) {
        let base = Date().addingTimeInterval(-100)
        _ = try await createConversation(host: host, model: model, userSystemPrompt: systemPromptA)
        let idA = try #require(await host.currentConversationID)
        try await host.selectConversation(conversationID: idA)
        await host.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .user, content: userContentA, timestamp: base.addingTimeInterval(1), toolCalls: []),
        ])
        _ = try await createConversation(host: host, model: model, userSystemPrompt: systemPromptB)
        let idB = try #require(await host.currentConversationID)
        try await host.selectConversation(conversationID: idB)
        await host.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .user, content: userContentB, timestamp: base.addingTimeInterval(1), toolCalls: []),
        ])
        try await resetCatalog(host: host, availableModels: availableModels ?? [model])
        return (idA, idB)
    }

    static func seedSearchableConversation(
        stack: ConversationPersistenceStack,
        model: Model,
        userContent: String,
        topic: String? = "Topic",
        lifecycle: ConversationLifecycleState = .active,
        ownerAccountID: UUID? = nil
    ) async throws -> (conversationID: UUID, messageID: UUID) {
        let userMsgID = UUID()
        let userMsg = Message(id: userMsgID, role: .user, content: userContent, timestamp: Date())
        let conv = try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: topic,
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            ownerAccountID: ownerAccountID
        )
        _ = try await stack.saveMessage(userMsg, for: conv.id, resourceManager: nil, logger: nil)
        if lifecycle != .active {
            try stack.conversationManager.updateConversationLifecycle(conversationID: conv.id, lifecycle: lifecycle)
        }
        try stack.conversationManager.resetConversationsFromCatalog(availableModels: [model])
        return (conv.id, userMsgID)
    }

    static func appendThinTranscriptMessage(
        local: LocalHarnessSessionPersistence,
        conversationID: UUID,
        message: Message,
        toolCallNames: [String]? = nil
    ) throws {
        let parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: local
        )
        let sequence = try local.nextTranscriptSequence(conversationID: conversationID)
        let namesJSON = (toolCallNames ?? []).map { "\"\($0)\"" }.joined(separator: ",")
        let thinString =
            "{\"id\":\"\(message.id.uuidString.lowercased())\",\"role\":\"\(message.role.rawValue)\",\"content\":\"\(message.content)\",\"timestamp\":\(message.timestamp.timeIntervalSince1970),\"toolCallNames\":[\(namesJSON)]}"
        let entry = SessionTranscriptEntry(
            sequence: sequence,
            entryId: SessionEntryID.fromMessageUUID(message.id),
            parentEntryId: parentEntryId,
            type: message.role == .system ? .system : .message,
            timestamp: message.timestamp,
            payloadJSON: thinString
        )
        try local.appendTranscriptEntry(conversationID: conversationID, entry: entry)
    }

    @discardableResult
    static func appendHarnessJournalEvent(
        local: LocalHarnessSessionPersistence,
        conversationID: UUID,
        stream: ConversationJournalStream,
        kind: String,
        innerPayloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int? = nil,
        coversEndEventID: Int? = nil,
        createdAt: Date = Date()
    ) throws -> Int {
        let entries = try local.readTranscriptEntries(conversationID: conversationID, request: .full)
        let globalNext = SessionTranscriptV2JournalTails.latestGlobalEventID(entries: entries) + 1
        let streamSeq: Int
        switch stream {
        case .raw:
            streamSeq = SessionTranscriptV2JournalTails.latestRawStreamSequence(entries: entries) + 1
        case .derived:
            streamSeq = SessionTranscriptV2JournalTails.latestDerivedStreamSequence(entries: entries) + 1
        }
        let env = SessionTranscriptJournalEnvelope(
            eventID: globalNext,
            journalStreamRaw: stream.rawValue,
            streamSequence: streamSeq,
            kind: kind,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            innerPayloadJSON: innerPayloadJSON
        )
        let json = try SessionTranscriptJournalEnvelopeCodec.encode(env)
        let entryType: SessionTranscriptEntryType = stream == .raw ? .conversationJournal : .derivedJournal
        let lock = try local.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }
        let parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: local
        )
        let seq = try local.nextTranscriptSequence(conversationID: conversationID)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: parentEntryId,
            type: entryType,
            timestamp: createdAt,
            payloadJSON: json
        )
        try local.appendMirroredTranscriptEntry(conversationID: conversationID, entry: entry)
        return globalNext
    }

    @discardableResult
    static func appendDerivedTurnSummaryEvent(
        stack: ConversationPersistenceStack,
        conversationID: UUID,
        payload: SummaryCreatedEventPayload,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?
    ) throws -> Int {
        try stack.derivedEventStore.appendTurnSummaryEvent(
            conversationID: conversationID,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: Date(),
            expectedDerivedSequence: nil
        )
        let (events, _) = stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
        return try #require(events.last { $0.kind == ConversationEventKind.turnSummaryEvent.rawValue }?.eventID)
    }

    static func patchDerivedJournalInnerPayload(
        local: LocalHarnessSessionPersistence,
        conversationID: UUID,
        globalEventID: Int,
        innerPayloadJSON: String
    ) throws {
        let entries = try local.readTranscriptEntries(conversationID: conversationID, request: .full)
        guard var entry = entries.first(where: { entry in
            guard entry.type == .derivedJournal,
                  let env = try? SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON)
            else { return false }
            return env.eventID == globalEventID
        }) else {
            throw ConversationServiceError.conversationNotFound
        }
        var env = try SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON)
        env.innerPayloadJSON = innerPayloadJSON
        entry.payloadJSON = try SessionTranscriptJournalEnvelopeCodec.encode(env)
        try local.updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
    }

    static func replaceRegistryMessageOverlay(
        manager: ConversationManager,
        conversationID: UUID,
        message: Message
    ) throws {
        guard var conversation = manager.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
            throw ConversationServiceError.conversationNotFound
        }
        conversation.messages[index] = message
        manager.replaceConversationInRegistry(conversation)
    }

    @discardableResult
    static func seedRegistryConversationWithImageUserMessage(
        host: HarnessRuntimeSession,
        local: LocalHarnessSessionPersistence,
        model: Model,
        availableModels: [Model]? = nil
    ) async throws -> UUID {
        try await host.createConversation(with: model, userSystemPrompt: "System", topic: nil, description: nil, metadata: nil)
        let conversationID = try #require(await host.currentConversationID)
        let blobRef = try local.putBlob(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            durability: .durable,
            originalName: "test.png",
            mimeType: "image/png",
            trust: "user-direct",
            ttlSeconds: nil,
            lane: .inbound
        )
        let user = Message(
            id: UUID(),
            role: .user,
            content: "With image",
            timestamp: Date(),
            images: [Message.Image(name: "test.png", path: SessionBlobImageRef.path(for: blobRef.id))],
            toolCalls: []
        )
        try await host.selectConversation(conversationID: conversationID)
        await host.testing_applyOrchestratorMessages([user])
        try await host.resetConversationsFromCatalog(availableModels: availableModels ?? [model])
        return conversationID
    }
}
