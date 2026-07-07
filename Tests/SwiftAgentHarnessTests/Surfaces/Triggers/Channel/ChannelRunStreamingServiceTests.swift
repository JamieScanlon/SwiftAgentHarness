import Foundation
import Logging
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Channel run streaming service")
struct ChannelRunStreamingServiceTests {
    @Test("Streams partial text to channel outbound during turn")
    func streamsPartialText() async throws {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let runID = UUID()
        let config = ChannelListenerConfig(enabled: true)
        let logger = Logger(label: "test")
        let bundle = try ChannelPluginFactory.build(channel: .slack, config: config, logger: logger)
        let plugin = bundle.plugin
        let listener = bundle.listener as! MockChannelListener
        let coordinator = ChannelSessionLifecycleCoordinator()
        let service = ChannelRunStreamingService(
            hub: hub,
            pluginLookup: { _ in plugin },
            lifecycleCoordinator: coordinator
        )
        await service.attach(
            conversationID: conversationID,
            target: ChannelRunStreamingTarget(
                channel: .slack,
                chatId: "C1",
                threadId: nil,
                replyToMessageId: "msg-root"
            )
        )

        try? await Task.sleep(for: .milliseconds(20))

        #expect(listener.typingCallCount >= 1)
        #expect(listener.typingChatIds.allSatisfy { $0 == "C1" })

        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(
                payload: RuntimeLifecycleEventPayload(
                    name: .turnStarted,
                    conversationID: conversationID,
                    runID: runID,
                    source: "tests"
                )
            ),
            runID: runID
        )
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "hello channel", runId: runID),
            runID: runID
        )
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicEventPayload.streamDone,
            runID: runID
        )
        await hub.broadcastPersisted(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.messagesRefreshPayload(
                messages: [Message(id: UUID(), role: .assistant, content: "hello channel")]
            ),
            transcriptSequence: 1
        )
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.runtimeLifecyclePayload(
                payload: RuntimeLifecycleEventPayload(
                    name: .turnCompleted,
                    conversationID: conversationID,
                    runID: runID,
                    source: "tests"
                )
            ),
            runID: runID
        )

        try? await Task.sleep(for: .milliseconds(150))
        #expect(listener.sentMessages.contains(where: { $0.text.contains("hello channel") }))
        let typingCountAfterTurn = listener.typingCallCount
        await service.detach(conversationID: conversationID)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(listener.typingCallCount == typingCountAfterTurn)
    }
}

@Suite("Default channel threading adapter")
struct DefaultChannelThreadingAdapterTests {
    @Test("Verbose detail routes to reply thread when no thread id exists")
    func verboseDetailRoutesToReplyThread() {
        let adapter = DefaultChannelThreadingAdapter()
        let target = adapter.deliveryTarget(
            chatId: "C1",
            threadId: nil,
            replyToMessageId: "reply-root",
            verboseDetailThread: true
        )
        #expect(target.threadId == "reply-root")
    }

    @Test("Main delivery keeps configured thread id")
    func mainDeliveryKeepsThread() {
        let adapter = DefaultChannelThreadingAdapter()
        let target = adapter.deliveryTarget(
            chatId: "C1",
            threadId: "T1",
            replyToMessageId: "reply-root",
            verboseDetailThread: false
        )
        #expect(target.threadId == "T1")
    }
}

@Suite("Channel streaming run consumer")
struct ChannelStreamingRunConsumerTests {
    @Test("Non-message tool fragments route to verbose thread sink")
    func verboseToolRouting() async {
        let config = ChannelListenerConfig(enabled: true)
        let logger = Logger(label: "test")
        let listener = MockChannelListener(id: .slack, config: config, logger: logger)
        let outbound = DefaultChannelOutboundAdapter(listener: listener, chunkLimit: 4000)
        let target = ChannelDeliveryTarget(chatId: "C1", threadId: nil, replyToMessageId: "root-msg")
        let mainSink = ChannelStreamingSurfaceSink(
            outbound: outbound,
            threading: DefaultChannelThreadingAdapter(),
            target: target,
            verboseDetailThread: false
        )
        let verboseSink = ChannelStreamingSurfaceSink(
            outbound: outbound,
            threading: DefaultChannelThreadingAdapter(),
            target: target,
            verboseDetailThread: true
        )
        let consumer = ChannelStreamingRunConsumer(
            capabilities: .finalOnly,
            mainSink: mainSink,
            verboseDetailSink: verboseSink
        )
        await consumer.ingest(.toolCall(toolName: "grep", toolCallId: "1", argumentsFragment: "{\"pattern\":\"foo\"}", blockIndex: nil))
        let verboseMessages = listener.sentMessages.filter { $0.threadId == "root-msg" }
        #expect(verboseMessages.count == 1)
        #expect(verboseMessages[0].text.contains("grep"))
    }
}
