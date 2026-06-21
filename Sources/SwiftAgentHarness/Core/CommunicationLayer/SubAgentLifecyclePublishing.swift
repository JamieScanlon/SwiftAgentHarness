import Foundation

public protocol SubAgentLifecyclePublishing: Sendable {
    func publishSubAgentLifecycleEvent(conversationID: UUID, pathSegments: [String], payload: SubAgentLifecycleTopicPayload) async
    func publishSubAgentLifecycleState(conversationID: UUID, pathSegments: [String], payload: SubAgentLifecycleTopicPayload) async
}

extension CommunicationLayer: SubAgentLifecyclePublishing {
    public func publishSubAgentLifecycleEvent(conversationID: UUID, pathSegments: [String], payload: SubAgentLifecycleTopicPayload) async {
        await broadcastSubAgentLifecycleEventIfSubscribed(conversationID: conversationID, pathSegments: pathSegments, payload: payload)
    }

    public func publishSubAgentLifecycleState(conversationID: UUID, pathSegments: [String], payload: SubAgentLifecycleTopicPayload) async {
        await broadcastSubAgentLifecycleStateIfSubscribed(conversationID: conversationID, pathSegments: pathSegments, payload: payload)
    }
}
