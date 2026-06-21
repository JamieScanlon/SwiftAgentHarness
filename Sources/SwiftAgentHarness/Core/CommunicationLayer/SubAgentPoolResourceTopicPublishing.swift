import Foundation

public protocol SubAgentPoolResourceTopicPublishing: Sendable {
    func broadcastSubAgentLifecycleEvent(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async
    func broadcastSubAgentLifecycleState(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async
    func broadcastSubAgentLifecycleSnapshot(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async
}

public extension SubAgentPoolResourceTopicPublishing {
    func broadcastSubAgentLifecycleSnapshot(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async {
        await broadcastSubAgentLifecycleEvent(
            conversationID: conversationID,
            pathSegments: pathSegments,
            payload: payload
        )
        await broadcastSubAgentLifecycleState(
            conversationID: conversationID,
            pathSegments: pathSegments,
            payload: payload
        )
    }
}

extension CommunicationLayer: SubAgentPoolResourceTopicPublishing {
    public func broadcastSubAgentLifecycleEvent(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async {
        await publishSubAgentLifecycleEvent(
            conversationID: conversationID,
            pathSegments: pathSegments,
            payload: payload
        )
    }

    public func broadcastSubAgentLifecycleState(
        conversationID: UUID,
        pathSegments: [String],
        payload: SubAgentLifecycleTopicPayload
    ) async {
        await publishSubAgentLifecycleState(
            conversationID: conversationID,
            pathSegments: pathSegments,
            payload: payload
        )
    }
}
