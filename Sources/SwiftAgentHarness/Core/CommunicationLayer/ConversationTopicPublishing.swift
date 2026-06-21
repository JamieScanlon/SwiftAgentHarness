import Foundation

/// Single outward fan-out API for `conversation/{id}/events` (`ConversationTopicEventPayload`).
public protocol ConversationTopicPublishing: Sendable {
    /// Persisted transcript-backed envelope (``transcriptSequence`` matches ``SessionTranscriptEntry.sequence``).
    func publishPersistedConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload, transcriptSequence: Int) async
    /// Transient streaming / lifecycle (`runId` + hub `turnOrdinal`; optional pool `modelCallId` for deltas).
    func publishTransientConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload, runID: UUID, modelCallId: UUID?) async
    /// Transitional / tests: classifies payload and fans out (prefer explicit persisted/transient in production).
    func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async
}

extension CommunicationLayer: ConversationTopicPublishing {
    public func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        guard await conversationEvents.hasSubscribers(forConversationID: conversationID) else { return }
        await conversationEvents.broadcastPersisted(
            conversationID: conversationID,
            payload: payload,
            transcriptSequence: transcriptSequence
        )
    }

    public func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        guard await conversationEvents.hasSubscribers(forConversationID: conversationID) else { return }
        await conversationEvents.broadcastTransient(
            conversationID: conversationID,
            payload: payload,
            runID: runID,
            modelCallId: modelCallId
        )
    }

    public func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        guard await conversationEvents.hasSubscribers(forConversationID: conversationID) else { return }
        await conversationEvents.broadcast(conversationID: conversationID, payload: payload)
    }
}

/// Hub-only wiring when tests inject ``APILayer/setConversationEventsWireResources`` without a full ``CommunicationLayer``.
public struct ConversationEventsHubOnlyPublisher: ConversationTopicPublishing {
    private let hub: ConversationEventsTopicHub

    public init(hub: ConversationEventsTopicHub) {
        self.hub = hub
    }

    public func publishPersistedConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        transcriptSequence: Int
    ) async {
        guard await hub.hasSubscribers(forConversationID: conversationID) else { return }
        await hub.broadcastPersisted(
            conversationID: conversationID,
            payload: payload,
            transcriptSequence: transcriptSequence
        )
    }

    public func publishTransientConversationEvent(
        conversationID: UUID,
        payload: ConversationTopicEventPayload,
        runID: UUID,
        modelCallId: UUID?
    ) async {
        guard await hub.hasSubscribers(forConversationID: conversationID) else { return }
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: payload,
            runID: runID,
            modelCallId: modelCallId
        )
    }

    public func publishConversationEvent(conversationID: UUID, payload: ConversationTopicEventPayload) async {
        guard await hub.hasSubscribers(forConversationID: conversationID) else { return }
        await hub.broadcast(conversationID: conversationID, payload: payload)
    }
}
