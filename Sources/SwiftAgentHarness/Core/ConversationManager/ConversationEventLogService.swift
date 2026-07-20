//
//  Raw journal markers (`message_appended`) on harness transcript.
//

import Foundation
import SwiftAgentKit

struct ConversationEventLogService: Sendable {
    private let harness: any HarnessSessionPersistence

    init(harness: any HarnessSessionPersistence) {
        self.harness = harness
    }

    func latestConversationEventID(conversationID: UUID) -> Int {
        let (_, frontier) = loadConversationEventsWithFrontier(conversationID: conversationID)
        return frontier
    }

    func nextConversationEventID(conversationID: UUID) -> Int {
        latestConversationEventID(conversationID: conversationID) + 1
    }

    func latestRawStreamSequence(conversationID: UUID) -> Int {
        TranscriptConversationJournalWriter.latestRawStreamSequence(
            harness: harness,
            conversationID: conversationID
        )
    }

    func latestRawTailMessageID(conversationID: UUID) -> UUID? {
        TranscriptConversationJournalWriter.latestRawTailMessageID(
            harness: harness,
            conversationID: conversationID
        )
    }

    func appendMessageAppendedEvents(
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID? = nil
    ) throws {
        try TranscriptConversationJournalWriter.appendMessageAppendedEvents(
            harness: harness,
            conversationID: conversationID,
            messages: messages,
            expectedLastMessageId: expectedLastMessageId
        )
    }

    func appendInteractionModeChangedEvent(
        conversationID: UUID,
        payload: InteractionModeChangedEventPayload,
        expectedRawSequence: Int? = nil
    ) throws {
        try TranscriptConversationJournalWriter.appendRawJournalEntry(
            harness: harness,
            conversationID: conversationID,
            kind: .interactionModeChanged,
            innerPayloadJSON: ConversationEventCodec.encode(payload),
            createdAt: Date(),
            expectedRawSequence: expectedRawSequence
        )
    }

    func eventIDForMessage(conversationID: UUID, messageID: UUID?) -> Int? {
        guard let messageID else { return nil }
        return TranscriptConversationJournalWriter.eventIDForMessage(
            harness: harness,
            conversationID: conversationID,
            messageID: messageID
        )
    }

    func loadConversationEventsWithFrontier(conversationID: UUID) -> (events: [CachedConversationEvent], frontierEventID: Int) {
        TranscriptConversationJournalWriter.loadEventsWithFrontier(
            harness: harness,
            conversationID: conversationID
        )
    }

    func projectedMessagesForConversation(_ conversation: ModelConversation, baseMessages: [Message]) -> [Message] {
        let (events, frontier) = loadConversationEventsWithFrontier(conversationID: conversation.id)
        return ConversationEventProjector.projectMessages(
            baseMessages: baseMessages,
            events: events,
            frontierEventID: frontier
        )
    }

    static func contentHash(for messages: [Message]) -> Int {
        var hasher = Hasher()
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.role.rawValue)
            hasher.combine(message.content)
            hasher.combine(message.toolCallId)
        }
        return hasher.finalize()
    }
}

extension ConversationEventKind {
    var journalStream: ConversationJournalStream {
        switch self {
        case .messageAppended, .interactionModeChanged:
            return .raw
        case .turnSummaryEvent, .turnFinalized, .compactionApplied, .contextCompactionCheckpoint, .memoryInjectionSnapshotCheckpoint, .toolResultTrimCheckpoint, .systemPromptAssemblyCheckpoint, .attachmentProjectionCheckpoint, .attachmentDigestCheckpoint, .runLifecycleEvent, .toolAuditLifecycleEvent, .toolUsageSummaryEvent, .checkpointInvalidated, .completionAnnounceEvent:
            return .derived
        }
    }
}
