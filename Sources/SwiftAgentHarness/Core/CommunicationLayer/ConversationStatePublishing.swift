import Foundation

/// Single outward fan-out API for `conversation/{id}/state` (`ConversationStatePayload`).
/// Prefer this over calling ``ConversationStateTopicHub/broadcast`` directly from route glue.
public protocol ConversationStatePublishing: Sendable {
    func publishConversationState(conversationID: UUID, payload: ConversationStatePayload) async
}

extension CommunicationLayer: ConversationStatePublishing {
    public func publishConversationState(conversationID: UUID, payload: ConversationStatePayload) async {
        await broadcastConversationStateIfSubscribed(conversationID: conversationID, payload: payload)
    }
}

/// Hub-only wiring when tests inject conversation state wire without a full ``CommunicationLayer``.
public struct ConversationStateHubOnlyPublisher: ConversationStatePublishing {
    private let hub: ConversationStateTopicHub

    public init(hub: ConversationStateTopicHub) {
        self.hub = hub
    }

    public func publishConversationState(conversationID: UUID, payload: ConversationStatePayload) async {
        guard await hub.hasSubscribers(forConversationID: conversationID) else { return }
        await hub.broadcast(conversationID: conversationID, payload: payload)
    }
}
