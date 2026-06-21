//
//  Conversation journal reads from harness transcript.
//

import Foundation
import SwiftAgentKit

extension ConversationManager {
    func loadConversationEventsWithFrontier(conversationID: UUID) -> ([CachedConversationEvent], Int) {
        TranscriptConversationJournalWriter.loadEventsWithFrontier(
            harness: harnessSessionPersistence,
            conversationID: conversationID
        )
    }

    func latestConversationEventID(conversationID: UUID) -> Int {
        let (_, frontier) = loadConversationEventsWithFrontier(conversationID: conversationID)
        return frontier
    }

    func latestRawTailMessageID(conversationID: UUID) -> UUID? {
        TranscriptConversationJournalWriter.latestRawTailMessageID(
            harness: harnessSessionPersistence,
            conversationID: conversationID
        )
    }

    func eventIDForMessage(conversationID: UUID, messageID: UUID?) -> Int? {
        guard let messageID else { return nil }
        return TranscriptConversationJournalWriter.eventIDForMessage(
            harness: harnessSessionPersistence,
            conversationID: conversationID,
            messageID: messageID
        )
    }
}
