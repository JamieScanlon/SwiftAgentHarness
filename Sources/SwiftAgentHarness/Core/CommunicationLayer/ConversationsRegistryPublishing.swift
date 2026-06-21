import Foundation

/// Publisher-facing API for account/session conversation catalog topic (`conversations/registry`).
public protocol ConversationsRegistryPublishing: Sendable {
    func publishConversationsRegistry(_ payload: ConversationsRegistryPayload) async
}

/// Hub-only wiring when tests inject conversations-registry wire without a full ``CommunicationLayer``.
public struct ConversationsRegistryHubOnlyPublisher: ConversationsRegistryPublishing {
    private let hub: ConversationsRegistryTopicHub

    public init(hub: ConversationsRegistryTopicHub) {
        self.hub = hub
    }

    public func publishConversationsRegistry(_ payload: ConversationsRegistryPayload) async {
        guard await hub.hasSubscribers(forTopic: ResourceTopicName.conversationsRegistry) else { return }
        await hub.broadcastConversationsRegistry(payload)
    }
}
