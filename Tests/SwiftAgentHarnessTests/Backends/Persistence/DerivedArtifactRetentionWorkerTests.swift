import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("DerivedArtifactRetentionWorker")
struct DerivedArtifactRetentionWorkerTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel(name: String = "retention:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("Retention sweep is a no-op without harness backend")
    func sweepIsNoOp() throws {
        let result = try DerivedArtifactRetentionWorker().runSweep(
            policy: DerivedArtifactRetentionPolicy(supersededOnly: true, pruneOrphans: true, batchLimit: 20)
        )
        #expect(result.totalDeletedRows == 0)
    }

    @Test("Retention sweep physically removes superseded derived transcript rows")
    func sweepRemovesSupersededDerivedRows() throws {
        let container = try makeContainer()
        let conversationManager = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: conversationManager, container: container)
        let (_, derived) = HarnessConversationTestFixtures.makeJournalPersistence(manager: conversationManager)
        let harness = conversationManager.harnessSessionPersistence
        let model = makeModel()
        let conversation = try conversationManager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = conversation.id

        let coveredMessageID = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [coveredMessageID],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: config,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        try derived.appendCheckpointInvalidation(
            conversationID: cid,
            kinds: [HarnessCheckpointInvalidationKind.contextCompaction],
            expectedDerivedSequence: nil
        )
        let before = try harness.readTranscriptEntries(conversationID: cid, request: .full)
        let derivedBefore = before.filter { $0.type == .derivedJournal }.count
        #expect(derivedBefore >= 2)

        let result = try DerivedArtifactRetentionWorker(harness: harness).runSweep(
            policy: DerivedArtifactRetentionPolicy(supersededOnly: true, pruneOrphans: false, batchLimit: 20),
            knownConversationIDs: [cid]
        )
        #expect(result.deletedDerivedEvents > 0)

        let after = try harness.readTranscriptEntries(conversationID: cid, request: .full)
        let checkpointRows = after.filter {
            guard $0.type == .derivedJournal,
                  let env = try? SessionTranscriptJournalEnvelopeCodec.decode($0.payloadJSON)
            else { return false }
            return env.kind == ConversationEventKind.contextCompactionCheckpoint.rawValue
        }
        #expect(checkpointRows.isEmpty)
        let events = conversationManager.loadConversationEventsWithFrontier(conversationID: cid).0
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: events,
                rawMiddle: [
                    Message(id: coveredMessageID, role: .user, content: "u", timestamp: Date(), toolCalls: []),
                ],
                config: config
            ) == nil
        )
    }

    @Test("Checkpoint invalidation logically supersedes derived compaction and summary")
    func invalidationSupersedesDerivedEvents() throws {
        let container = try makeContainer()
        let conversationManager = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: conversationManager, container: container)
        let (_, derived) = HarnessConversationTestFixtures.makeJournalPersistence(manager: conversationManager)
        let model = makeModel()
        let conversation = try conversationManager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = conversation.id

        let coveredMessageID = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [coveredMessageID],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: config,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        let summaryPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "summary",
            coveredMessageIDs: [coveredMessageID],
            firstCoveredMessageID: coveredMessageID,
            basedOnEventID: 1,
            startEventID: 1,
            endEventID: 1,
            basedOnTailMessageID: coveredMessageID,
            succeeded: true,
            createdAt: Date()
        )
        try derived.appendTurnSummaryEvent(
            conversationID: cid,
            payloadJSON: ConversationEventCodec.encode(summaryPayload),
            basedOnEventID: 1,
            coversStartEventID: 1,
            coversEndEventID: 1,
            createdAt: Date(),
            expectedDerivedSequence: nil
        )
        try derived.appendCheckpointInvalidation(
            conversationID: cid,
            kinds: [
                HarnessCheckpointInvalidationKind.contextCompaction,
                HarnessCheckpointInvalidationKind.turnSummaryEvent,
            ],
            expectedDerivedSequence: nil
        )

        let events = conversationManager.loadConversationEventsWithFrontier(conversationID: cid).0
        let rawMiddle = [
            Message(id: coveredMessageID, role: .user, content: "u", timestamp: Date(), toolCalls: []),
        ]
        #expect(
            ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: events,
                rawMiddle: rawMiddle,
                config: config
            ) == nil
        )
        let turnSummaryFloor = ContextCompactionCheckpointSupport.derivedInvalidationFloor(
            events: events,
            invalidatedKindKeys: [HarnessCheckpointInvalidationKind.turnSummaryEvent]
        )
        let activeSummary = events.filter {
            $0.kind == ConversationEventKind.turnSummaryEvent.rawValue && $0.eventID > turnSummaryFloor
        }
        #expect(activeSummary.isEmpty)
        #expect(events.contains { $0.kind == ConversationEventKind.checkpointInvalidated.rawValue })
    }

    @Test("Post-invalidation append keeps derived sequencing monotonic")
    func postInvalidationAppendMaintainsSequence() throws {
        let container = try makeContainer()
        let conversationManager = ConversationManager(container: container)
        HarnessConversationTestFixtures.attachSharedInMemoryHarness(to: conversationManager, container: container)
        let (_, derived) = HarnessConversationTestFixtures.makeJournalPersistence(manager: conversationManager)
        let model = makeModel()
        let conversation = try conversationManager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = conversation.id

        let coveredMessageID = UUID()
        let compacted = Message(id: UUID(), role: .assistant, content: "compact", timestamp: Date(), toolCalls: [])
        let config = ContextCompactionConfiguration(
            enabled: true,
            ollamaServerURL: URL(string: "http://localhost:11434")!,
            model: "m",
            fallbackContextLimitTokens: 131_072,
            charactersPerToken: 4,
            maxCompactedMiddleMessages: 15
        )
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [coveredMessageID],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: config,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        try derived.appendCheckpointInvalidation(
            conversationID: cid,
            kinds: [HarnessCheckpointInvalidationKind.contextCompaction],
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 2)
        try derived.appendContextCompactionCheckpoint(
            conversationID: cid,
            rawMiddleMessageIDs: [coveredMessageID],
            compactedMiddleMessages: [compacted],
            kind: .summarized,
            config: config,
            strategyRawValue: nil,
            cachePolicyFingerprint: nil,
            expectedDerivedSequence: nil
        )
        #expect(derived.latestDerivedStreamSequence(conversationID: cid) == 3)
    }
}
