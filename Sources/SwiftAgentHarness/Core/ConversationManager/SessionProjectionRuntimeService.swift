import Foundation
import SwiftAgentKit

/// UI session projection cache: per-conversation projected transcripts and publish frontier state.
actor SessionProjectionRuntimeService {
    struct Cache {
        struct PublishState {
            let frontierEventID: Int
            let contentHash: Int
        }

        var projectedMessagesByConversationID: [UUID: [Message]] = [:]
        var projectionPublishStateByConversationID: [UUID: PublishState] = [:]
    }

    private let persistenceDomain: ConversationPersistenceDomain
    private let selection: ConversationSelectionAccessing
    private var cache = Cache()

    init(
        persistenceDomain: ConversationPersistenceDomain,
        selection: ConversationSelectionAccessing
    ) {
        self.persistenceDomain = persistenceDomain
        self.selection = selection
    }

    func syncFromRegistry(conversationID: UUID, conversation: ModelConversation) async {
        let projected = await persistenceDomain.projectedMessagesForUI(conversation: conversation)
        cache.projectedMessagesByConversationID[conversationID] = projected
        await selection.setCurrentMessagesIfSelected(conversationID: conversationID, messages: projected)
    }

    func replaceAllProjectedMessages(_ byConversationID: [UUID: [Message]]) {
        cache.projectedMessagesByConversationID = byConversationID
    }

    func applySnapshotIfNotStale(
        conversationID: UUID,
        messages: [Message],
        frontierEventID: Int,
        contentHash: Int
    ) -> SessionProjectionApplyOutcome {
        let currentFrontier = cache.projectionPublishStateByConversationID[conversationID]?.frontierEventID ?? 0
        if frontierEventID < currentFrontier {
            return .droppedStale(projectedFrontier: frontierEventID, currentFrontier: currentFrontier)
        }
        let previousState = cache.projectionPublishStateByConversationID[conversationID]
        let shouldPublish = previousState?.frontierEventID != frontierEventID
            || previousState?.contentHash != contentHash
        cache.projectedMessagesByConversationID[conversationID] = messages
        cache.projectionPublishStateByConversationID[conversationID] = Cache.PublishState(
            frontierEventID: frontierEventID,
            contentHash: contentHash
        )
        return .applied(shouldPublish: shouldPublish)
    }

    func projectedMessages(for conversation: ModelConversation) -> [Message] {
        cache.projectedMessagesByConversationID[conversation.id] ?? conversation.messages
    }

    func testing_seedProjectionPublishState(conversationID: UUID, frontierEventID: Int, contentHash: Int) {
        cache.projectionPublishStateByConversationID[conversationID] = Cache.PublishState(
            frontierEventID: frontierEventID,
            contentHash: contentHash
        )
    }

    func testing_clearProjectionPublishState(conversationID: UUID) {
        cache.projectionPublishStateByConversationID[conversationID] = nil
    }
}
