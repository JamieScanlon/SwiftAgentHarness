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
    private let lifecycleCoordinator: ChannelSessionLifecycleCoordinator?
    private var sessions: [UUID: ChannelRunStreamingSession] = [:]

    init(
        hub: ConversationEventsTopicHub,
        pluginLookup: @escaping @Sendable (ChannelId) async -> ChannelPlugin?,
        lifecycleCoordinator: ChannelSessionLifecycleCoordinator? = nil
    ) {
        self.hub = hub
        self.pluginLookup = pluginLookup
        self.lifecycleCoordinator = lifecycleCoordinator
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
        var typingKeepalive: ChannelTypingKeepalive?
        if plugin.capabilities.typingIndicators, let heartbeat = plugin.heartbeat {
            let keepalive = ChannelTypingKeepalive()
            await keepalive.start(chatId: target.chatId) { chatId in
                await heartbeat.sendTyping(chatId: chatId)
            }
            typingKeepalive = keepalive
        }
        if let lifecycleCoordinator {
            await lifecycleCoordinator.registerStreaming(
                conversationID: conversationID,
                channel: target.channel,
                driveTask: driveTask,
                typingKeepalive: typingKeepalive
            )
        }
        sessions[conversationID] = ChannelRunStreamingSession(source: source, driveTask: driveTask)
    }

    func detach(conversationID: UUID) async {
        guard let session = sessions.removeValue(forKey: conversationID) else { return }
        if let lifecycleCoordinator {
            _ = await lifecycleCoordinator.drainSession(conversationID: conversationID)
        } else {
            session.driveTask.cancel()
        }
        await session.source.teardown()
    }
}

private struct ChannelRunStreamingSession {
    let source: CommunicationLayerConversationStreamSource
    let driveTask: Task<Void, Never>
}

/// Wraps a channel stream consumer and detaches the run subscription when the turn ends.
actor ChannelRunStreamingSessionConsumer: ConversationStreamConsumer {
    private let inner: ChannelStreamingRunConsumer
    private let onTurnEnded: @Sendable () async -> Void

    init(inner: ChannelStreamingRunConsumer, onTurnEnded: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.onTurnEnded = onTurnEnded
    }

    func ingest(_ partial: ChatStreamingPartial) async {
        await inner.ingest(partial)
    }

    func flushSegment() async {
        await inner.flushSegment()
    }

    func finishTurn(final: StreamingFinalPayload) async {
        await inner.finishTurn(final: final)
        await onTurnEnded()
    }

    func cancelTurn() async {
        await inner.cancelTurn()
        await onTurnEnded()
    }
}
