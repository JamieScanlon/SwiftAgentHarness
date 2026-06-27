import Foundation

/// Embedded in-process source for `conversation/{id}/events` driving surface consumers.
public actor CommunicationLayerConversationStreamSource {
    private let hub: ConversationEventsTopicHub
    private let conversationID: UUID
    private var subscriberToken: EmbeddedTopicSubscriberToken?
    private var continuation: AsyncStream<DecodedConversationTopicEvent>.Continuation?
    private let snapshotMessagesJSONUTF8: @Sendable (UUID) async -> String

    public init(
        hub: ConversationEventsTopicHub,
        conversationID: UUID,
        snapshotMessagesJSONUTF8: @escaping @Sendable (UUID) async -> String = { _ in "[]" }
    ) {
        self.hub = hub
        self.conversationID = conversationID
        self.snapshotMessagesJSONUTF8 = snapshotMessagesJSONUTF8
    }

    public func events() -> AsyncStream<DecodedConversationTopicEvent> {
        AsyncStream { continuation in
            Task {
                await self.bindContinuation(continuation)
            }
            continuation.onTermination = { _ in
                Task { await self.teardown() }
            }
        }
    }

    public func start(driving consumer: any ConversationStreamConsumer) async {
        let stream = events()
        let driver = ConversationStreamSurfaceDriver()
        await driver.consume(events: stream, consumer: consumer)
    }

    public func teardown() async {
        if let token = subscriberToken {
            let topic = ConversationTopicFormat.topic(conversationID: conversationID)
            await hub.unsubscribeInProcess(token: token, topic: topic)
            await hub.unregisterInProcessSubscriber(token)
        }
        subscriberToken = nil
        continuation?.finish()
        continuation = nil
    }

    private func bindContinuation(_ continuation: AsyncStream<DecodedConversationTopicEvent>.Continuation) async {
        guard subscriberToken == nil else { return }
        self.continuation = continuation
        let token = await hub.registerInProcessSubscriber { line in
            Task { await self.handleIncomingLine(line) }
        }
        subscriberToken = token
        await hub.subscribeInProcess(
            token: token,
            conversationID: conversationID,
            replay: .totalOrderSince(nil),
            transcriptReplay: .empty,
            snapshotMessagesJSONUTF8: snapshotMessagesJSONUTF8,
            snapshotTranscriptSequence: nil
        )
    }

    private func handleIncomingLine(_ line: String) {
        continuation?.yield(ConversationTopicWireDecoding.decodeEvent(line: line))
    }
}
