import EasyJSON
import Foundation

/// Delivers a committed `MessagePresentation` to the active surface for a conversation.
public protocol MessageOutputDelivering: Sendable {
    func deliver(presentation: MessagePresentation, conversationID: UUID, metadata: MessageOutputDeliveryMetadata) async
}

public struct MessageOutputDeliveryMetadata: Sendable, Equatable {
    public var originSurface: String?
    public var originSenderID: String?
    public var chatId: String?
    public var threadId: String?
    public var toolCallID: String?

    public init(
        originSurface: String? = nil,
        originSenderID: String? = nil,
        chatId: String? = nil,
        threadId: String? = nil,
        toolCallID: String? = nil
    ) {
        self.originSurface = originSurface
        self.originSenderID = originSenderID
        self.chatId = chatId
        self.threadId = threadId
        self.toolCallID = toolCallID
    }
}

/// Routes message-tool output to registered surface deliverers (channels, etc.).
public actor MessageOutputDeliveryRegistry {
    public static let shared = MessageOutputDeliveryRegistry()

    private var deliverers: [String: any MessageOutputDelivering] = [:]

    public func register(surfaceID: String, deliverer: any MessageOutputDelivering) {
        deliverers[surfaceID] = deliverer
    }

    public func unregister(surfaceID: String) {
        deliverers.removeValue(forKey: surfaceID)
    }

    public func deliver(
        presentation: MessagePresentation,
        conversationID: UUID,
        metadata: MessageOutputDeliveryMetadata
    ) async {
        guard let surface = metadata.originSurface,
              let deliverer = deliverers[surface] else {
            return
        }
        await deliverer.deliver(presentation: presentation, conversationID: conversationID, metadata: metadata)
    }
}
