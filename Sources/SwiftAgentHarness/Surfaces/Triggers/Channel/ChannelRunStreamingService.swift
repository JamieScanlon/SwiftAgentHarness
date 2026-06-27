import Foundation

struct ChannelRunStreamingTarget: Sendable, Equatable {
    var channel: ChannelId
    var chatId: String
    var threadId: String?
    var replyToMessageId: String?
}

/// Attaches live conversation topic streaming to channel outbound for isolated/threaded trigger turns.
actor ChannelRunStreamingService {
    private let hub: ConversationEventsTopicHub
    private let pluginLookup: @Sendable (ChannelId) async -> ChannelPlugin?
    private var sessions: [UUID: ChannelRunStreamingSession] = [:]

    init(
        hub: ConversationEventsTopicHub,
        pluginLookup: @escaping @Sendable (ChannelId) async -> ChannelPlugin?
    ) {
        self.hub = hub
        self.pluginLookup = pluginLookup
    }

    func attach(conversationID: UUID, target: ChannelRunStreamingTarget) async {
        await detach(conversationID: conversationID)
        guard let plugin = await pluginLookup(target.channel) else { return }

        let deliveryTarget = ChannelDeliveryTarget(
            chatId: target.chatId,
            threadId: target.threadId,
            replyToMessageId: target.replyToMessageId
        )
        let threading = plugin.threading
        let mainSink = ChannelStreamingSurfaceSink(
            outbound: plugin.outbound,
            threading: threading,
            target: deliveryTarget,
            verboseDetailThread: false
        )
        var verboseDetailSink: ChannelStreamingSurfaceSink?
        if plugin.capabilities.threading, threading != nil {
            verboseDetailSink = ChannelStreamingSurfaceSink(
                outbound: plugin.outbound,
                threading: threading,
                target: deliveryTarget,
                verboseDetailThread: true
            )
        }
        let engineConsumer = ChannelStreamingRunConsumer(
            capabilities: plugin.streamingCapabilities,
            mainSink: mainSink,
            verboseDetailSink: verboseDetailSink
        )
        let source = CommunicationLayerConversationStreamSource(
            hub: hub,
            conversationID: conversationID
        )
        let consumer = ChannelRunStreamingSessionConsumer(inner: engineConsumer) { [self] in
            await self.detach(conversationID: conversationID)
        }
        let driveTask = Task {
            await source.start(driving: consumer)
        }
        sessions[conversationID] = ChannelRunStreamingSession(source: source, driveTask: driveTask)
    }

    func detach(conversationID: UUID) async {
        guard let session = sessions.removeValue(forKey: conversationID) else { return }
        await session.source.teardown()
        session.driveTask.cancel()
    }
}

private struct ChannelRunStreamingSession {
    let source: CommunicationLayerConversationStreamSource
    let driveTask: Task<Void, Never>
}
