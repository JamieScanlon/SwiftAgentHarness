import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationManager", .serialized)
struct ConversationManagerTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeManager(container: ModelContainer) -> ConversationManager {
        let cm = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: cm, container: container)
        return cm
    }

    private func makeModel(
        name: String = "cm:test",
        modelProtocol: ModelProtocol = .openAIAPI,
        capabilities: [LLMCapability] = [.completion]
    ) -> Model {
        Model(
            protocol: modelProtocol,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: capabilities,
            modelProtocol: modelProtocol
        )
    }

    @Test("reset from empty cache yields empty registry")
    func resetFromEmptyYieldsEmpty() throws {
        let container = try makeContainer()
        let cm = makeManager(container: container)
        try cm.resetConversationsFromCatalog(availableModels: [])
        #expect(cm.listConversationInfo().isEmpty)
    }

    @Test("createConversation persists and reset reloads")
    func createAndResetRoundTrip() throws {
        let container = try makeContainer()
        let model = makeModel()
        var cm = makeManager(container: container)
        _ = try cm.createConversation(
            with: model,
            userSystemPrompt: "You are a test helper.",
            topic: "T1",
            description: "D1",
            metadata: .object(["k": .string("v")])
        )
        #expect(cm.listConversationInfo().count == 1)
        #expect(cm.listConversationInfo().first?.topic == "T1")

        cm = makeManager(container: container)
        try cm.resetConversationsFromCatalog(availableModels: [model])
        #expect(cm.listConversationInfo().count == 1)
        let reloaded = try #require(cm.listConversationInfo().first)
        #expect(reloaded.topic == "T1")
        #expect(reloaded.description == "D1")
        #expect(reloaded.systemPrompt == "You are a test helper.")
    }

    @Test("deleteConversation removes registry row and cache row")
    func deleteRemoves() throws {
        let container = try makeContainer()
        let model = makeModel()
        let cm = makeManager(container: container)
        let created = try cm.createConversation(with: model, userSystemPrompt: "sys")
        let id = created.id
        try cm.deleteConversation(conversationID: id)
        #expect(cm.listConversationInfo().isEmpty)
        #expect(cm.modelConversation(id: id) == nil)
    }

    @Test("copyConversation produces a new id and target model")
    func copyConversation() throws {
        let container = try makeContainer()
        let source = makeModel(name: "source")
        let target = makeModel(name: "target")
        let cm = makeManager(container: container)
        _ = try cm.createConversation(with: source, userSystemPrompt: "orig")
        let sourceID = try #require(cm.listConversationInfo().first?.id)
        let copy = try cm.copyConversation(from: sourceID, to: target, systemPrompt: "copy-prompt")
        #expect(copy.id != sourceID)
        #expect(copy.model.id == target.id)
        #expect(copy.systemPrompt == "copy-prompt")
        #expect(cm.listConversationInfo().count == 2)
    }

    @Test("updateConversationMetadata persists across reload")
    func metadataUpdateRoundTrip() throws {
        let container = try makeContainer()
        let model = makeModel()
        var cm = makeManager(container: container)
        let conv = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: "old")
        let id = conv.id
        _ = try cm.updateConversationMetadata(
            conversationID: id,
            topic: "new-topic",
            description: "new-desc",
            metadata: .object(["x": .integer(1)])
        )

        cm = makeManager(container: container)
        try cm.resetConversationsFromCatalog(availableModels: [model])
        let reloaded = try #require(cm.modelConversation(id: id))
        #expect(reloaded.topic == "new-topic")
        #expect(reloaded.description == "new-desc")
    }

    @Test("HarnessRuntimeSession actor serializes concurrent createConversation calls")
    func runtimeSessionConcurrentCreates() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = makeModel()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    try await runtimeSession.createConversation(with: model, userSystemPrompt: "c")
                }
            }
            for try await _ in group {}
        }
        let listed = await runtimeSession.listConversationInfo()
        #expect(listed.count == 24)
        let uniqueIDs = Set(listed.map(\.id))
        #expect(uniqueIDs.count == 24)
    }

    @Test("persistSplitSelectingNewThread records branch ref on parent harness catalog conversation")
    func splitRecordsBranchIndexOnParent() throws {
        let container = try makeContainer()
        let model = makeModel()
        let cm = makeManager(container: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-split-backend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        cm.setHarnessSessionPersistenceOverride(local)
        let created = try cm.createConversation(with: model, userSystemPrompt: "sys")
        let parentID = created.id

        let userMessage = Message(id: UUID(), role: .user, content: "hello", timestamp: Date())
        let parentHead = try #require(try local.activeHeadEntryId(conversationID: parentID))
        let seq = try local.nextTranscriptSequence(conversationID: parentID)
        let transcriptEntry = try SessionTranscriptMapping.entry(
            from: userMessage,
            sequence: seq,
            parentEntryId: parentHead,
            transcriptRunID: nil
        )
        try local.appendTranscriptEntry(conversationID: parentID, entry: transcriptEntry)

        try cm.resetConversationsFromCatalog(availableModels: [model])
        let sourceConversation = try #require(cm.modelConversation(id: parentID))
        #expect(sourceConversation.messages.count >= 2)

        let split = try cm.persistSplitSelectingNewThread(
            sourceConversation: sourceConversation,
            atUserMessageID: userMessage.id
        )

        let parentAgain = try #require(cm.modelConversation(id: parentID))
        #expect(parentAgain.branchChildren.count == 1)
        #expect(parentAgain.branchChildren[0].childConversationID == split.newConversationID)
        #expect(parentAgain.branchChildren[0].branchedAtMessageID == userMessage.id)

        let child = try #require(cm.modelConversation(id: split.newConversationID))
        #expect(child.parentConversationID == parentID)
    }

    @Test("persistSplitSelectingNewThread copies ~/.swiftAgentHarness/conversations/<id> plan files")
    func splitCopiesConversationDirectoryFiles() throws {
        let container = try makeContainer()
        let model = makeModel()
        let cm = makeManager(container: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-split-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try LocalHarnessSessionPersistence(root: root)
        cm.setHarnessSessionPersistenceOverride(local)
        let created = try cm.createConversation(
            with: model,
            userSystemPrompt: "sys",
            interactionMode: .plan
        )
        let parentID = created.id
        defer { _ = AgentPlanStore.removeConversationDirectory(for: parentID) }

        let planURL = AgentPlanStore.planURL(for: parentID)
        try AgentPlanStore.ensureConversationDirectory(for: parentID)
        try "# Plan\n\n## Tasks\n[ ] id:\(UUID().uuidString) - task".write(to: planURL, atomically: true, encoding: .utf8)

        let userMessage = Message(id: UUID(), role: .user, content: "hello", timestamp: Date())
        let parentHead = try #require(try local.activeHeadEntryId(conversationID: parentID))
        let seq = try local.nextTranscriptSequence(conversationID: parentID)
        let transcriptEntry = try SessionTranscriptMapping.entry(
            from: userMessage,
            sequence: seq,
            parentEntryId: parentHead,
            transcriptRunID: nil
        )
        try local.appendTranscriptEntry(conversationID: parentID, entry: transcriptEntry)

        try cm.resetConversationsFromCatalog(availableModels: [model])
        let sourceConversation = try #require(cm.modelConversation(id: parentID))

        let split = try cm.persistSplitSelectingNewThread(
            sourceConversation: sourceConversation,
            atUserMessageID: userMessage.id
        )
        defer { _ = AgentPlanStore.removeConversationDirectory(for: split.newConversationID) }

        let childPlanURL = AgentPlanStore.planURL(for: split.newConversationID)
        #expect(FileManager.default.fileExists(atPath: childPlanURL.path))
        let childPlan = try String(contentsOf: childPlanURL, encoding: .utf8)
        #expect(childPlan.contains("## Tasks"))
    }

    @Test("nextForkLineageTitle returns deterministic suffix for fork branches")
    func nextForkLineageTitleUsesNumberedSuffix() throws {
        let container = try makeContainer()
        let model = makeModel()
        let cm = makeManager(container: container)
        _ = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: "Thread")
        _ = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: "Thread #1")

        let next = try cm.nextForkLineageTitle(baseTitle: "Thread")
        #expect(next == "Thread #2")
    }

    @Test("copyConversation remaps inherited journal payloads to child message storage ids")
    func copyConversationInheritsJournalWithRemappedMessageIds() throws {
        let sourceModel = makeModel(name: "journal-source")
        let targetModel = makeModel(name: "journal-target")
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "copy-journal-remap")
        defer { try? FileManager.default.removeItem(at: root) }
        let cm = stack.conversationManager
        _ = try cm.createConversation(with: sourceModel, userSystemPrompt: "sys")
        let sourceID = try #require(cm.listConversationInfo().first?.id)

        let userStorage = UUID()
        let userMsg = Message(id: userStorage, role: .user, content: "hi", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: sourceID, message: userMsg)
        try cm.resetConversationsFromCatalog(availableModels: [sourceModel])
        try stack.appendMessageJournalEntries(conversationID: sourceID, messages: [userMsg])
        let summaryPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "sum",
            coveredMessageIDs: [userStorage],
            firstCoveredMessageID: userStorage,
            basedOnEventID: 1,
            startEventID: 1,
            endEventID: 1,
            basedOnTailMessageID: userStorage,
            succeeded: true,
            createdAt: Date()
        )
        try stack.appendTurnSummaryEvent(
            conversationID: sourceID,
            payloadJSON: ConversationEventCodec.encode(summaryPayload),
            basedOnEventID: 1,
            coversStartEventID: 1,
            coversEndEventID: 1,
            createdAt: Date()
        )

        let copy = try cm.copyConversation(from: sourceID, to: targetModel, systemPrompt: "copy-prompt")
        let childID = copy.id

        let (childEvents, _) = cm.loadConversationEventsWithFrontier(conversationID: childID)
        #expect(childEvents.count == 2)

        let childUser = try #require(
            cm.modelConversation(id: childID)?.messages.first(where: { $0.role == .user })
        )

        let appended = try #require(childEvents.first { $0.kind == ConversationEventKind.messageAppended.rawValue })
        let decodedAppend = try #require(ConversationEventCodec.decode(MessageAppendedEventPayload.self, from: appended.payloadJSON))
        #expect(decodedAppend.messageID == childUser.id)

        let summaryEv = try #require(childEvents.first { $0.kind == ConversationEventKind.turnSummaryEvent.rawValue })
        let decodedSummary = try #require(ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: summaryEv.payloadJSON))
        #expect(decodedSummary.coveredMessageIDs == [childUser.id])
        #expect(decodedSummary.basedOnEventID == 1)
    }

    @Test("Branch turn-summary payload event references are remapped to child event numbering")
    func branchTurnSummaryPayloadEventReferencesAreRemapped() throws {
        let model = makeModel(name: "branch-remap")
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "branch-summary-remap")
        defer { try? FileManager.default.removeItem(at: root) }
        let cm = stack.conversationManager
        _ = try cm.createConversation(with: model, userSystemPrompt: "sys")
        let sourceID = try #require(cm.listConversationInfo().first?.id)
        let userStorage = UUID()
        let user = Message(id: userStorage, role: .user, content: "u", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: sourceID, message: user)
        try cm.resetConversationsFromCatalog(availableModels: [model])
        let appendedEventID = try HarnessConversationTestFixtures.appendHarnessJournalEvent(
            local: local,
            conversationID: sourceID,
            stream: .raw,
            kind: ConversationEventKind.messageAppended.rawValue,
            innerPayloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: userStorage)),
            basedOnEventID: nil
        )
        _ = try HarnessConversationTestFixtures.appendHarnessJournalEvent(
            local: local,
            conversationID: sourceID,
            stream: .derived,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            innerPayloadJSON: ConversationEventCodec.encode(
                SummaryCreatedEventPayload(
                    summaryMessageID: UUID(),
                    summaryContent: "s",
                    coveredMessageIDs: [userStorage],
                    firstCoveredMessageID: userStorage,
                    basedOnEventID: appendedEventID,
                    startEventID: appendedEventID,
                    endEventID: appendedEventID,
                    basedOnTailMessageID: userStorage,
                    succeeded: true,
                    createdAt: Date()
                )
            ),
            basedOnEventID: appendedEventID,
            coversStartEventID: appendedEventID,
            coversEndEventID: appendedEventID
        )
        let copied = try cm.copyConversation(from: sourceID, to: model, systemPrompt: "sys")
        let (childEvents, _) = cm.loadConversationEventsWithFrontier(conversationID: copied.id)
        let childSummary = try #require(childEvents.first(where: { $0.kind == ConversationEventKind.turnSummaryEvent.rawValue }))
        let payload = try #require(ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: childSummary.payloadJSON))
        #expect(payload.basedOnEventID == 1)
        #expect(payload.startEventID == 1)
        #expect(payload.endEventID == 1)
    }

    @Test("listConversationSummaries uses catalog title and first user prompt for list topic")
    func listSummariesUseCatalogDisplayTopic() throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let cm = ConversationManager(container: container)
        cm.setHarnessSessionPersistenceOverride(harness)
        let titledID = UUID()
        let promptOnlyID = UUID()
        var titled = SessionCatalogRecord(
            id: titledID,
            topic: nil,
            description: nil,
            messageCount: 3,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        titled.title = "Harness Title"
        titled.firstUserPrompt = "ignored when title is set"
        titled.agentId = SessionPersistenceLayout.defaultAgentId
        try harness.bootstrapEmptyConversation(titled)
        var promptOnly = SessionCatalogRecord(
            id: promptOnlyID,
            topic: nil,
            description: nil,
            messageCount: 2,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue
        )
        promptOnly.firstUserPrompt = "First user words for sidebar"
        promptOnly.agentId = SessionPersistenceLayout.defaultAgentId
        try harness.bootstrapEmptyConversation(promptOnly)
        let page = cm.listConversationSummaries(query: ConversationListQuery(limit: 50, offset: 0))
        let titledSummary = try #require(page.items.first { $0.id == titledID })
        let promptSummary = try #require(page.items.first { $0.id == promptOnlyID })
        #expect(titledSummary.topic == "Harness Title")
        #expect(promptSummary.topic == "First user words for sidebar")
    }

    @Test("listConversationSummaries reads catalog when in-memory registry is empty")
    func listSummariesFromCatalogWithoutRegistryHydrate() throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let cm = ConversationManager(container: container)
        cm.setHarnessSessionPersistenceOverride(harness)
        let parentID = UUID()
        let otherID = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: cm, conversationID: parentID)
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: cm, conversationID: otherID)
        #expect(cm.listConversationInfo().isEmpty)
        #expect(try harness.catalogConversation(id: parentID) != nil)
        #expect(try harness.catalogConversation(id: otherID) != nil)
        let page = cm.listConversationSummaries(query: ConversationListQuery(limit: 50, offset: 0))
        #expect(page.totalCount == 2)
        #expect(page.items.contains { $0.id == parentID })
        #expect(page.items.contains { $0.id == otherID })
        #expect(page.items.count == 2)
    }

    @Test("modelConversation lazy-hydrates from catalog when registry is empty")
    func modelConversationLazyHydratesFromCatalog() throws {
        let container = try makeContainer()
        let harness = InMemoryHarnessSessionPersistence()
        let cm = ConversationManager(container: container)
        cm.setHarnessSessionPersistenceOverride(harness)
        let conversationID = UUID()
        try HarnessConversationTestFixtures.bootstrapInMemoryCatalogRow(manager: cm, conversationID: conversationID)
        #expect(cm.listConversationInfo().isEmpty)
        let hydrated = cm.modelConversation(id: conversationID)
        #expect(hydrated != nil)
        #expect(hydrated?.id == conversationID)
        #expect(cm.listConversationInfo().count == 1)
    }

    @Test("listConversationSummaries filters by parentConversationID")
    func listSummariesParentFilter() throws {
        let container = try makeContainer()
        let model = makeModel()
        let cm = makeManager(container: container)
        let parent = try cm.createConversation(with: model, userSystemPrompt: "parent")
        let childID = UUID()
        guard let inMemory = cm.harnessSessionPersistence as? InMemoryHarnessSessionPersistence else {
            Issue.record("expected in-memory harness persistence")
            return
        }
        var childRecord = SessionCatalogRecord(
            id: childID,
            topic: "branch-child",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: model.modelName,
            interactionModeRaw: InteractionMode.chat.rawValue,
            modeProfileID: nil
        )
        childRecord.agentId = SessionPersistenceLayout.defaultAgentId
        childRecord.parentConversationID = parent.id
        childRecord.lineageKind = .branch
        childRecord.origin = .user
        try inMemory.bootstrapEmptyConversation(childRecord)
        try cm.resetConversationsFromCatalog(availableModels: [model])
        _ = try cm.createConversation(with: model, userSystemPrompt: "other-root")
        let query = ConversationListQuery(limit: 50, offset: 0, parentConversationID: parent.id)
        let page = cm.listConversationSummaries(query: query)
        #expect(page.totalCount == 1)
        #expect(page.items.first?.id == childID)
    }

    @Test("BranchJournalCheckpointFilter rejects empty-scope memory injection checkpoints")
    func branchCheckpointFilterRejectsInvalidMemoryInjectionWire() throws {
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                MemoryInjectionSnapshotCheckpointWire(
                    schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    injectionFingerprint: "fp",
                    snapshotJSON: "{}",
                    scopeMessageIDs: [],
                    createdAt: Date()
                )
            )
        )
        #expect(
            BranchJournalCheckpointFilter.shouldCopyCheckpointEvent(
                event,
                allowedMessageIDs: [UUID()]
            ) == false
        )
    }

    @Test("branch journal scopes interaction_mode_changed events to inherited raw prefix")
    func branchJournalScopesInteractionModeMarkersToRawPrefix() {
        #expect(
            DerivedArtifactContractMatrix.branchInheritanceRule(forPersistedKind: ConversationEventKind.interactionModeChanged.rawValue)
                == .rawPrefixScoped
        )
    }

    @Test("BranchJournalCheckpointFilter rejects empty tool-trim checkpoints")
    func branchCheckpointFilterRejectsInvalidToolTrimWire() throws {
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.toolResultTrimCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ToolResultTrimCheckpointWire(
                    schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    coveredMessageIDs: [],
                    trimmedToolCallIds: [],
                    configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
                    createdAt: Date()
                )
            )
        )
        #expect(
            BranchJournalCheckpointFilter.shouldCopyCheckpointEvent(
                event,
                allowedMessageIDs: [UUID()]
            ) == false
        )
    }

    @Test("BranchJournalCheckpointFilter enforces per-kind admissibility matrix")
    func branchCheckpointFilterPerKindMatrix() throws {
        let allowedA = UUID()
        let allowedB = UUID()
        let covered = [allowedA, allowedB]
        let validCompaction = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 1,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: covered,
                    syntheticMessages: covered.map { ContextCompactionMessageDTO(id: $0, role: "assistant", content: "s") },
                    configFingerprint: "fp",
                    basedOnEventID: 1,
                    basedOnTailMessageID: covered.last,
                    createdAt: Date()
                )
            )
        )
        let invalidCompaction = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.contextCompactionCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                ContextCompactionCheckpointPayload(
                    schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
                    kind: .summarized,
                    coveredMessageIDs: covered,
                    syntheticMessages: [ContextCompactionMessageDTO(id: UUID(), role: "assistant", content: "only-one")],
                    configFingerprint: "fp",
                    basedOnEventID: 1,
                    basedOnTailMessageID: UUID(),
                    createdAt: Date()
                )
            )
        )
        let validSystemPrompt = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                SystemPromptAssemblyCheckpointWire(
                    schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    assemblyFingerprint: "mode+tools+prompt",
                    createdAt: Date()
                )
            )
        )
        let invalidSystemPrompt = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 4,
            kind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                SystemPromptAssemblyCheckpointWire(
                    schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                    basedOnEventID: 1,
                    assemblyFingerprint: "",
                    createdAt: Date()
                )
            )
        )

        struct Case {
            let event: CachedConversationEvent
            let allowSystemPrompt: Bool
            let expected: Bool
        }
        let matrix: [Case] = [
            .init(event: validCompaction, allowSystemPrompt: true, expected: true),
            .init(event: invalidCompaction, allowSystemPrompt: true, expected: false),
            .init(event: validSystemPrompt, allowSystemPrompt: true, expected: true),
            .init(event: validSystemPrompt, allowSystemPrompt: false, expected: false),
            .init(event: invalidSystemPrompt, allowSystemPrompt: true, expected: false),
        ]

        for row in matrix {
            #expect(
                BranchJournalCheckpointFilter.shouldCopyCheckpointEvent(
                    row.event,
                    allowedMessageIDs: Set(covered),
                    allowSystemPromptAssemblyCheckpoint: row.allowSystemPrompt
                ) == row.expected
            )
        }
    }

    @Test("copyConversation omits unknown derived event kinds from branch inheritance")
    func copyConversationOmitsUnknownDerivedKinds() throws {
        let model = makeModel(name: "unknown-kind")
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "copy-unknown-derived")
        defer { try? FileManager.default.removeItem(at: root) }
        let cm = stack.conversationManager
        _ = try cm.createConversation(with: model, userSystemPrompt: "sys")
        let sourceID = try #require(cm.listConversationInfo().first?.id)

        let sourceMessage = Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: sourceID, message: sourceMessage)
        try cm.resetConversationsFromCatalog(availableModels: [model])
        _ = try HarnessConversationTestFixtures.appendHarnessJournalEvent(
            local: local,
            conversationID: sourceID,
            stream: .raw,
            kind: ConversationEventKind.messageAppended.rawValue,
            innerPayloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: sourceMessage.id)),
            basedOnEventID: nil
        )
        _ = try HarnessConversationTestFixtures.appendHarnessJournalEvent(
            local: local,
            conversationID: sourceID,
            stream: .derived,
            kind: "custom_derived_event",
            innerPayloadJSON: "{\"value\":\"parent-only\"}",
            basedOnEventID: 1
        )

        let copied = try cm.copyConversation(from: sourceID, to: model, systemPrompt: "sys")
        let (childEvents, _) = cm.loadConversationEventsWithFrontier(conversationID: copied.id)
        #expect(childEvents.map(\.kind) == [ConversationEventKind.messageAppended.rawValue])
    }

    @Test("copyConversation skips system prompt assembly checkpoints when prompt diverges")
    func copyConversationSkipsSystemPromptCheckpointOnPromptDivergence() throws {
        let sourceModel = makeModel(name: "source")
        let targetModel = makeModel(name: "target")
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "copy-prompt-checkpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let cm = stack.conversationManager
        _ = try cm.createConversation(with: sourceModel, userSystemPrompt: "base prompt")
        let sourceID = try #require(cm.listConversationInfo().first?.id)

        let sourceMessage = Message(id: UUID(), role: .user, content: "hello", timestamp: Date(), toolCalls: [])
        try HarnessConversationTestFixtures.appendThinTranscriptMessage(local: local, conversationID: sourceID, message: sourceMessage)
        try cm.resetConversationsFromCatalog(availableModels: [sourceModel])
        _ = try HarnessConversationTestFixtures.appendHarnessJournalEvent(
            local: local,
            conversationID: sourceID,
            stream: .raw,
            kind: ConversationEventKind.messageAppended.rawValue,
            innerPayloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: sourceMessage.id)),
            basedOnEventID: nil
        )
        try stack.persistSystemPromptAssemblyCheckpoint(
            conversationID: sourceID,
            wire: SystemPromptAssemblyCheckpointWire(
                schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
                basedOnEventID: 1,
                assemblyFingerprint: "base-fingerprint",
                createdAt: Date()
            )
        )

        let copied = try cm.copyConversation(from: sourceID, to: targetModel, systemPrompt: "different prompt")
        let (childEvents, _) = cm.loadConversationEventsWithFrontier(conversationID: copied.id)
        #expect(childEvents.map(\.kind) == [ConversationEventKind.messageAppended.rawValue])
    }
}
