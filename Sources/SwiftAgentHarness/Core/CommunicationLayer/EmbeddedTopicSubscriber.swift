import Foundation

/// Shared token for in-process topic subscribers.
public struct EmbeddedTopicSubscriberToken: Hashable, Sendable {
    public let uuid: UUID

    public init() {
        self.uuid = UUID()
    }
}

struct EmbeddedTopicSubscriberEntry {
    var topics: Set<String> = []
    let sendJSON: @Sendable (String) async -> Void
}
