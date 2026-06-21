import Foundation

/// Outbound fan-out API for trace topics (`trace/{conversationId}`, `trace/server`).
public protocol TraceTopicPublishing: Sendable {
    func publishConversationTrace(conversationID: UUID, payload: TraceTopicPayload) async
    func publishServerTrace(payload: TraceTopicPayload) async
}

extension CommunicationLayer: TraceTopicPublishing {
    public func publishConversationTrace(conversationID: UUID, payload: TraceTopicPayload) async {
        await broadcastConversationTraceIfSubscribed(conversationID: conversationID, payload: payload)
    }

    public func publishServerTrace(payload: TraceTopicPayload) async {
        await broadcastServerTraceIfSubscribed(payload: payload)
    }
}
