import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("CommunicationLayerConversationStreamSource")
struct CommunicationLayerConversationStreamSourceTests {
    @Test("Drives consumer end-to-end from published topic events")
    func endToEndFromHub() async throws {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let runID = UUID()
        let assistant = Message(id: UUID(), role: .assistant, content: "from topic")
        let consumer = RecordingConversationStreamConsumer()

        let source = CommunicationLayerConversationStreamSource(
            hub: hub,
            conversationID: conversationID,
            snapshotMessagesJSONUTF8: { _ in ConversationTopicWireEncoding.messagesJSONArrayUTF8(from: []) }
        )

        let driveTask = Task {
            await source.start(driving: consumer)
        }

        try? await Task.sleep(for: .milliseconds(20))

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
            payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "tok", runId: runID),
            runID: runID
        )
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicEventPayload.streamDone,
            runID: runID
        )
        await hub.broadcastPersisted(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.messagesRefreshPayload(messages: [assistant]),
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

        try? await Task.sleep(for: .milliseconds(100))
        await source.teardown()
        driveTask.cancel()

        let actions = await consumer.actions
        #expect(actions.contains(.ingest(.text("tok"))))
        #expect(actions.contains(.flushSegment))
        #expect(actions.contains(.finish(StreamingFinalPayload(text: "from topic"))))
    }
}
