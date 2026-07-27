import Foundation

/// Attaches a ``TUIApp`` to a conversation's event stream for the life of a run.
///
/// This is the terminal analogue of the channel surface's run streaming service, and the
/// piece whose absence forced every host to hand-roll the subscribe/drive/teardown
/// lifecycle. `TUIApp` already satisfies ``ConversationStreamConsumer``; all that was
/// missing was something to construct the source and drive it.
public actor TUIRunStreamingService {
    private struct Attachment {
        let source: CommunicationLayerConversationStreamSource
        let task: Task<Void, Never>
    }

    private let hub: ConversationEventsTopicHub
    private var attachments: [UUID: Attachment] = [:]

    public init(hub: ConversationEventsTopicHub) {
        self.hub = hub
    }

    public var attachedConversationIDs: Set<UUID> { Set(attachments.keys) }

    /// Subscribes to `conversation/{id}/events` and drives `app` until ``detach(conversationID:)``.
    /// Re-attaching the same conversation is a no-op.
    public func attach(
        conversationID: UUID,
        app: TUIApp,
        snapshotMessagesJSONUTF8: @escaping @Sendable (UUID) async -> String = { _ in "[]" }
    ) async {
        guard attachments[conversationID] == nil else { return }
        let source = CommunicationLayerConversationStreamSource(
            hub: hub,
            conversationID: conversationID,
            snapshotMessagesJSONUTF8: snapshotMessagesJSONUTF8
        )
        let task = Task { await source.start(driving: app) }
        attachments[conversationID] = Attachment(source: source, task: task)
    }

    public func detach(conversationID: UUID) async {
        guard let attachment = attachments.removeValue(forKey: conversationID) else { return }
        await attachment.source.teardown()
        attachment.task.cancel()
    }

    public func detachAll() async {
        for conversationID in attachments.keys {
            await detach(conversationID: conversationID)
        }
    }
}
