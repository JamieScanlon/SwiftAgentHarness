import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Harness derived journal patch", .serialized)
struct HarnessDerivedJournalPatchTests {
    @Test("patchDerivedJournalInnerPayload preserves v2 journal read after in-place repair")
    func patchPreservesDerivedJournalDecode() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "derived-patch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [
                Message(id: UUID(), role: .assistant, content: "body", timestamp: Date(), toolCalls: []),
            ]
        )

        let assistantID = try #require(
            fixture.stack.conversationManager.rawMessages(conversationID: conversationID)?
                .first { $0.role == .assistant && $0.content == "body" }?.id
        )

        let badPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "bad",
            coveredMessageIDs: [assistantID],
            firstCoveredMessageID: assistantID,
            basedOnEventID: 999_999,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: Date()
        )
        let summaryEventID = try HarnessConversationTestFixtures.appendDerivedTurnSummaryEvent(
            stack: fixture.stack,
            conversationID: conversationID,
            payload: badPayload,
            basedOnEventID: nil,
            coversStartEventID: 1,
            coversEndEventID: 1
        )
        let (beforePatch, _) = fixture.stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
        #expect(beforePatch.contains { $0.kind == ConversationEventKind.turnSummaryEvent.rawValue })

        let summaryMessageID = UUID()
        let goodPayload = SummaryCreatedEventPayload(
            summaryMessageID: summaryMessageID,
            summaryContent: "rolled",
            coveredMessageIDs: [assistantID],
            firstCoveredMessageID: assistantID,
            basedOnEventID: summaryEventID,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: Date()
        )
        try HarnessConversationTestFixtures.patchDerivedJournalInnerPayload(
            local: fixture.local,
            conversationID: conversationID,
            globalEventID: summaryEventID,
            innerPayloadJSON: ConversationEventCodec.encode(goodPayload)
        )

        let (afterPatch, _) = fixture.stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
        let summary = try #require(afterPatch.first { $0.eventID == summaryEventID })
        #expect(summary.kind == ConversationEventKind.turnSummaryEvent.rawValue)
        let decoded = try #require(ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: summary.payloadJSON))
        #expect(decoded.summaryContent == "rolled")
    }

    @Test("patchDerivedJournalInnerPayload updates JSONL while transcript write lock is held")
    func patchPreservesDerivedJournalDecodeWhileLockHeld() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "derived-patch-lock-held")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel()
        let conversationID = try await HarnessConversationTestFixtures.seedRegistryConversation(
            host: fixture.host,
            model: model,
            extraMessages: [
                Message(id: UUID(), role: .assistant, content: "body", timestamp: Date(), toolCalls: []),
            ]
        )
        let assistantID = try #require(
            fixture.stack.conversationManager.rawMessages(conversationID: conversationID)?
                .first { $0.role == .assistant && $0.content == "body" }?.id
        )
        let summaryEventID = try HarnessConversationTestFixtures.appendDerivedTurnSummaryEvent(
            stack: fixture.stack,
            conversationID: conversationID,
            payload: SummaryCreatedEventPayload(
                summaryMessageID: UUID(),
                summaryContent: "bad",
                coveredMessageIDs: [assistantID],
                firstCoveredMessageID: assistantID,
                basedOnEventID: 999_999,
                startEventID: 1,
                endEventID: 1,
                succeeded: true,
                createdAt: Date()
            ),
            basedOnEventID: nil,
            coversStartEventID: 1,
            coversEndEventID: 1
        )
        let lock = try fixture.local.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }
        try HarnessConversationTestFixtures.patchDerivedJournalInnerPayload(
            local: fixture.local,
            conversationID: conversationID,
            globalEventID: summaryEventID,
            innerPayloadJSON: ConversationEventCodec.encode(
                SummaryCreatedEventPayload(
                    summaryMessageID: UUID(),
                    summaryContent: "rolled-under-lock",
                    coveredMessageIDs: [assistantID],
                    firstCoveredMessageID: assistantID,
                    basedOnEventID: summaryEventID,
                    startEventID: 1,
                    endEventID: 1,
                    succeeded: true,
                    createdAt: Date()
                )
            )
        )
        let (afterPatch, _) = fixture.stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
        let summary = try #require(afterPatch.first { $0.eventID == summaryEventID })
        let decoded = try #require(ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: summary.payloadJSON))
        #expect(decoded.summaryContent == "rolled-under-lock")
    }
}
