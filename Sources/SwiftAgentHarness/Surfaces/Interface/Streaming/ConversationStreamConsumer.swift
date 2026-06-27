import Foundation

/// Surface contract for consuming decoded conversation stream events.
public protocol ConversationStreamConsumer: Sendable {
    func ingest(_ partial: ChatStreamingPartial) async
    func flushSegment() async
    func finishTurn(final: StreamingFinalPayload) async
    func cancelTurn() async
}

public extension ConversationStreamConsumer {
    func flushSegment() async {}
}
