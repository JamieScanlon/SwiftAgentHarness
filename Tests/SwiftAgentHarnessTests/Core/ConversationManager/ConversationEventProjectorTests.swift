import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationEventProjector")
struct ConversationEventProjectorTests {
    @Test("Summary event projects additively and hides covered messages")
    func summaryProjectionHidesCoveredMessages() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let assistantA = Message(id: UUID(), role: .assistant, content: "a1", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let tool = Message(id: UUID(), role: .tool, content: "tool", timestamp: now.addingTimeInterval(2), toolCalls: [], toolCallId: "tc-1")
        let assistantB = Message(id: UUID(), role: .assistant, content: "a2", timestamp: now.addingTimeInterval(3), toolCalls: [])

        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "summary",
            coveredMessageIDs: [assistantA.id, tool.id],
            firstCoveredMessageID: assistantA.id,
            basedOnEventID: 4,
            startEventID: 2,
            endEventID: 3,
            succeeded: true,
            createdAt: now.addingTimeInterval(4)
        )
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )

        let projected = ConversationEventProjector.projectMessages(
            baseMessages: [user, assistantA, tool, assistantB],
            events: [event]
        )
        #expect(projected.count == 3)
        #expect(projected[0].id == user.id)
        #expect(projected[1].content == "summary")
        #expect(projected[2].id == assistantB.id)
    }

    @Test("Turn summaries at or below turn_summary_event invalidation floor are ignored (logical prune)")
    func turnSummaryIgnoredAfterInvalidationMarker() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let assistantA = Message(id: UUID(), role: .assistant, content: "a1", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let tool = Message(id: UUID(), role: .tool, content: "tool", timestamp: now.addingTimeInterval(2), toolCalls: [], toolCallId: "tc-1")
        let assistantB = Message(id: UUID(), role: .assistant, content: "a2", timestamp: now.addingTimeInterval(3), toolCalls: [])

        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "summary",
            coveredMessageIDs: [assistantA.id, tool.id],
            firstCoveredMessageID: assistantA.id,
            basedOnEventID: 4,
            startEventID: 2,
            endEventID: 3,
            succeeded: true,
            createdAt: now.addingTimeInterval(4)
        )
        let summaryEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let invPayload = CheckpointInvalidatedEventPayload(kinds: [HarnessCheckpointInvalidationKind.turnSummaryEvent])
        let invalidationEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.checkpointInvalidated.rawValue,
            payloadJSON: ConversationEventCodec.encode(invPayload)
        )

        let withoutFloor = ConversationEventProjector.projectMessages(
            baseMessages: [user, assistantA, tool, assistantB],
            events: [summaryEvent]
        )
        #expect(withoutFloor.count == 3)

        let withFloor = ConversationEventProjector.projectMessages(
            baseMessages: [user, assistantA, tool, assistantB],
            events: [summaryEvent, invalidationEvent]
        )
        #expect(withFloor.count == 4)
        #expect(!withFloor.contains(where: { $0.content == "summary" }))

        let metrics = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, assistantA, tool, assistantB],
            events: [summaryEvent, invalidationEvent]
        ).metrics
        #expect(metrics.causalityRejectedSummaryCount == 1)
    }

    @Test("Overlapping summary ranges prefer newer event")
    func overlappingSummariesPreferNewer() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let b = Message(id: UUID(), role: .assistant, content: "b", timestamp: now.addingTimeInterval(2), toolCalls: [])
        let c = Message(id: UUID(), role: .assistant, content: "c", timestamp: now.addingTimeInterval(3), toolCalls: [])

        let oldPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "old",
            coveredMessageIDs: [a.id, b.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 3,
            startEventID: 2,
            endEventID: 3,
            succeeded: true,
            createdAt: now.addingTimeInterval(4)
        )
        let newPayload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "new",
            coveredMessageIDs: [b.id, c.id],
            firstCoveredMessageID: b.id,
            basedOnEventID: 4,
            startEventID: 3,
            endEventID: 4,
            succeeded: true,
            createdAt: now.addingTimeInterval(5)
        )
        let oldEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 10,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(oldPayload)
        )
        let newEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 11,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(newPayload)
        )

        let projected = ConversationEventProjector.projectMessages(
            baseMessages: [user, a, b, c],
            events: [oldEvent, newEvent]
        )
        #expect(projected.contains(where: { $0.content == "new" }))
        #expect(!projected.contains(where: { $0.content == "old" }))
    }

    @Test("Causally invalid summary is rejected")
    func causallyInvalidSummaryRejected() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "invalid",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 99, // ahead of frontier
            startEventID: 2,
            endEventID: 2,
            succeeded: true,
            createdAt: now.addingTimeInterval(2)
        )
        let summaryEvent = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [summaryEvent]
        )
        #expect(projection.messages.map(\.id) == [user.id, a.id])
        #expect(projection.metrics.causalityRejectedSummaryCount == 1)
    }

    @Test("Projection frontier is monotonic under churn")
    func projectionFrontierMonotonicUnderChurn() {
        let conversationID = UUID()
        let now = Date()
        var events: [CachedConversationEvent] = []
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        var baseMessages: [Message] = [user]
        var lastFrontier = 0

        for index in 1...50 {
            let msg = Message(id: UUID(), role: .assistant, content: index % 2 == 0 ? "" : "chunk\(index)", timestamp: now.addingTimeInterval(Double(index)), toolCalls: [])
            baseMessages.append(msg)
            let appendEvent = CachedConversationEvent(
                conversationID: conversationID,
                eventID: index,
                kind: ConversationEventKind.messageAppended.rawValue,
                payloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: msg.id))
            )
            events.append(appendEvent)

            if index % 10 == 0 {
                let payload = SummaryCreatedEventPayload(
                    summaryMessageID: UUID(),
                    summaryContent: "s\(index)",
                    coveredMessageIDs: [baseMessages[max(1, index - 2)].id, baseMessages[max(1, index - 1)].id],
                    firstCoveredMessageID: baseMessages[max(1, index - 2)].id,
                    basedOnEventID: index,
                    startEventID: max(1, index - 1),
                    endEventID: index,
                    succeeded: true,
                    createdAt: now.addingTimeInterval(Double(index) + 0.1)
                )
                events.append(
                    CachedConversationEvent(
                        conversationID: conversationID,
                        eventID: index + 1000,
                        kind: ConversationEventKind.turnSummaryEvent.rawValue,
                        payloadJSON: ConversationEventCodec.encode(payload)
                    )
                )
            }

            let projection = ConversationEventProjector.projectMessagesWithMetrics(
                baseMessages: baseMessages,
                events: events
            )
            #expect(projection.frontierEventID >= lastFrontier)
            lastFrontier = projection.frontierEventID
        }
    }

    @Test("succeeded false does not fold transcript")
    func unsuccessfulSummarySkipped() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "should not appear",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 2,
            startEventID: 1,
            endEventID: 2,
            succeeded: false,
            createdAt: now.addingTimeInterval(2)
        )
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [event]
        )
        #expect(projection.messages.map(\.id) == [user.id, a.id])
        #expect(projection.metrics.unsuccessfulSummarySkippedCount == 1)
    }

    @Test("Undecodable summary JSON increments decodeRejectedSummaryCount")
    func decodeRejectedSummary() {
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: Date(), toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: Date(), toolCalls: [])
        let event = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: "{not json",
            createdAt: Date()
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [event]
        )
        #expect(projection.metrics.decodeRejectedSummaryCount == 1)
    }

    @Test("Disjoint summaries preserved when newer summary overlaps only older region")
    func disjointSummariesPreservedWhenOverlapIsPartial() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now.addingTimeInterval(1), toolCalls: [])
        let b = Message(id: UUID(), role: .assistant, content: "b", timestamp: now.addingTimeInterval(2), toolCalls: [])
        let c = Message(id: UUID(), role: .assistant, content: "c", timestamp: now.addingTimeInterval(3), toolCalls: [])

        let sA = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "SA",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 1,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: now.addingTimeInterval(4)
        )
        let sC = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "SC",
            coveredMessageIDs: [c.id],
            firstCoveredMessageID: c.id,
            basedOnEventID: 3,
            startEventID: 3,
            endEventID: 3,
            succeeded: true,
            createdAt: now.addingTimeInterval(5)
        )
        let sAB = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "SAB",
            coveredMessageIDs: [a.id, b.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 4,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: now.addingTimeInterval(6)
        )
        let events = [
            CachedConversationEvent(conversationID: UUID(), eventID: 30, kind: ConversationEventKind.turnSummaryEvent.rawValue, payloadJSON: ConversationEventCodec.encode(sAB)),
            CachedConversationEvent(conversationID: UUID(), eventID: 20, kind: ConversationEventKind.turnSummaryEvent.rawValue, payloadJSON: ConversationEventCodec.encode(sC)),
            CachedConversationEvent(conversationID: UUID(), eventID: 10, kind: ConversationEventKind.turnSummaryEvent.rawValue, payloadJSON: ConversationEventCodec.encode(sA)),
        ]
        let projected = ConversationEventProjector.projectMessages(
            baseMessages: [user, a, b, c],
            events: events
        )
        #expect(projected.contains(where: { $0.content == "SAB" }))
        #expect(projected.contains(where: { $0.content == "SC" }))
        #expect(!projected.contains(where: { $0.content == "SA" }))
    }

    @Test("Explicit frontier from loader admits basedOn above batch max eventID")
    func explicitFrontierAdmitsSummaryWhenBatchMaxIsLower() {
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: Date(), toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: Date(), toolCalls: [])
        let summaryID = UUID()
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: summaryID,
            summaryContent: "sum",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 100,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: Date()
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let implicitFrontier = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [ev]
        )
        #expect(implicitFrontier.metrics.causalityRejectedSummaryCount == 1)

        let explicitFrontier = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [ev],
            frontierEventID: 100
        )
        #expect(explicitFrontier.metrics.causalityRejectedSummaryCount == 0)
        #expect(explicitFrontier.frontierEventID == 100)
        #expect(explicitFrontier.messages.contains { $0.id == summaryID })
    }

    @Test("Empty base transcript returns empty projection with frontier from events")
    func emptyBaseMessagesReturnsEmpty() {
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 7,
            kind: ConversationEventKind.messageAppended.rawValue,
            payloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: UUID()))
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [],
            events: [ev],
            frontierEventID: 7
        )
        #expect(projection.messages.isEmpty)
        #expect(projection.frontierEventID == 7)
    }

    @Test("Inverted start/end range rejects summary as causality")
    func invertedStartEndRejectsSummary() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now, toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "bad range",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 2,
            startEventID: 5,
            endEventID: 2,
            succeeded: true,
            createdAt: now
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [ev]
        )
        #expect(projection.messages.map(\.id) == [user.id, a.id])
        #expect(projection.metrics.causalityRejectedSummaryCount == 1)
    }

    @Test("Empty coveredMessageIDs rejects summary as causality")
    func emptyCoveredIDsRejectsSummary() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "empty covered",
            coveredMessageIDs: [],
            firstCoveredMessageID: nil,
            basedOnEventID: 1,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: now
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user],
            events: [ev]
        )
        #expect(projection.messages.map(\.id) == [user.id])
        #expect(projection.metrics.causalityRejectedSummaryCount == 1)
    }

    @Test("Covered ID not present in base rejects summary as invalid structural")
    func coveredNotSubsetOfBaseRejects() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let orphan = UUID()
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "orphan",
            coveredMessageIDs: [orphan],
            firstCoveredMessageID: orphan,
            basedOnEventID: 1,
            startEventID: 1,
            endEventID: 1,
            succeeded: true,
            createdAt: now
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 2,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user],
            events: [ev]
        )
        #expect(projection.messages.map(\.id) == [user.id])
        #expect(projection.metrics.invalidStructuralSummaryCount == 1)
    }

    @Test("Wrong firstCoveredMessageID rejects summary as invalid structural")
    func wrongFirstCoveredRejects() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now, toolCalls: [])
        let b = Message(id: UUID(), role: .assistant, content: "b", timestamp: now, toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "wrong first",
            coveredMessageIDs: [a.id, b.id],
            firstCoveredMessageID: b.id,
            basedOnEventID: 3,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: now
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 4,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a, b],
            events: [ev]
        )
        #expect(projection.messages.map(\.id) == [user.id, a.id, b.id])
        #expect(projection.metrics.invalidStructuralSummaryCount == 1)
    }

    @Test("message_appended events do not mutate base transcript without summary")
    func messageAppendedOnlyLeavesBaseUnchanged() {
        let conversationID = UUID()
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let ghost = Message(id: UUID(), role: .assistant, content: "ghost", timestamp: now, toolCalls: [])
        let appendEv = CachedConversationEvent(
            conversationID: conversationID,
            eventID: 1,
            kind: ConversationEventKind.messageAppended.rawValue,
            payloadJSON: ConversationEventCodec.encode(MessageAppendedEventPayload(messageID: ghost.id))
        )
        let projected = ConversationEventProjector.projectMessages(
            baseMessages: [user],
            events: [appendEv]
        )
        #expect(projected.map(\.id) == [user.id])
    }

    @Test("Duplicate summaryMessageID keeps higher eventID and increments dedupe metric")
    func duplicateSummaryMessageIDDedupes() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now, toolCalls: [])
        let summaryID = UUID()
        let older = SummaryCreatedEventPayload(
            summaryMessageID: summaryID,
            summaryContent: "older",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 2,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: now
        )
        let newer = SummaryCreatedEventPayload(
            summaryMessageID: summaryID,
            summaryContent: "newer",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: a.id,
            basedOnEventID: 2,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: now.addingTimeInterval(1)
        )
        let events = [
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 10,
                kind: ConversationEventKind.turnSummaryEvent.rawValue,
                payloadJSON: ConversationEventCodec.encode(older)
            ),
            CachedConversationEvent(
                conversationID: UUID(),
                eventID: 20,
                kind: ConversationEventKind.turnSummaryEvent.rawValue,
                payloadJSON: ConversationEventCodec.encode(newer)
            ),
        ]
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: events
        )
        #expect(projection.messages.contains { $0.id == summaryID && $0.content == "newer" })
        #expect(projection.metrics.deduplicatedSummaryEventCount == 1)
    }

    @Test("Nil firstCoveredMessageID rejects when base has covered messages")
    func nilFirstCoveredRejects() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let a = Message(id: UUID(), role: .assistant, content: "a", timestamp: now, toolCalls: [])
        let payload = SummaryCreatedEventPayload(
            summaryMessageID: UUID(),
            summaryContent: "nil first",
            coveredMessageIDs: [a.id],
            firstCoveredMessageID: nil,
            basedOnEventID: 2,
            startEventID: 1,
            endEventID: 2,
            succeeded: true,
            createdAt: now
        )
        let ev = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 3,
            kind: ConversationEventKind.turnSummaryEvent.rawValue,
            payloadJSON: ConversationEventCodec.encode(payload)
        )
        let projection = ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: [user, a],
            events: [ev]
        )
        #expect(projection.messages.map(\.id) == [user.id, a.id])
        #expect(projection.metrics.invalidStructuralSummaryCount == 1)
    }

    @Test("Non-summary event kinds are ignored for projection output")
    func turnFinalizedDoesNotChangeTranscript() {
        let now = Date()
        let user = Message(id: UUID(), role: .user, content: "u", timestamp: now, toolCalls: [])
        let finalized = CachedConversationEvent(
            conversationID: UUID(),
            eventID: 5,
            kind: ConversationEventKind.turnFinalized.rawValue,
            payloadJSON: ConversationEventCodec.encode(
                TurnFinalizedEventPayload(basedOnEventID: 4, createdAt: now)
            )
        )
        let projected = ConversationEventProjector.projectMessages(
            baseMessages: [user],
            events: [finalized]
        )
        #expect(projected.map(\.id) == [user.id])
    }
}
