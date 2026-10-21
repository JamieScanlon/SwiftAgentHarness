import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TUI run streaming service")
struct TUIRunStreamingServiceTests {
    private func makeApp() -> TUIApp {
        TUIApp(terminal: VirtualTerminal(columns: 60, rows: 12))
    }

    private func broadcastTurnStart(hub: ConversationEventsTopicHub, conversationID: UUID, runID: UUID) async {
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
    }

    @Test("Attach returns with the conversation subscription live")
    func attachSubscribesBeforeReturning() async {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let service = TUIRunStreamingService(hub: hub)

        await service.attach(conversationID: conversationID, app: makeApp())

        // Transient events are never replayed, so anything broadcast before this point would be lost.
        #expect(await hub.hasSubscribers(forConversationID: conversationID))
        await service.detach(conversationID: conversationID)
    }

    @Test("A turn broadcast immediately after attach reaches the app")
    func firstDeltaIsNotDropped() async {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let runID = UUID()
        let app = makeApp()
        let service = TUIRunStreamingService(hub: hub)

        await service.attach(conversationID: conversationID, app: app)
        await broadcastTurnStart(hub: hub, conversationID: conversationID, runID: runID)
        await hub.broadcastTransient(
            conversationID: conversationID,
            payload: ConversationTopicWireEncoding.contentDeltaTextFragmentPayload(text: "hello tui", runId: runID),
            runID: runID
        )

        // The driver ignores partials until it sees `turnStarted`, so an active turn with an
        // assistant message means neither transient event was dropped.
        #expect(await HarnessAsyncTestSupport.waitUntil {
            guard await app.isTurnActive() else { return false }
            return await app.transcriptMessages().contains { $0.role == .assistant }
        })
        await service.detach(conversationID: conversationID)
    }

    @Test("Re-attaching the same conversation keeps a single subscription")
    func reattachIsNoOp() async {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let service = TUIRunStreamingService(hub: hub)

        await service.attach(conversationID: conversationID, app: makeApp())
        await service.attach(conversationID: conversationID, app: makeApp())
        #expect(await service.attachedConversationIDs == [conversationID])

        await service.detach(conversationID: conversationID)
        #expect(await !hub.hasSubscribers(forConversationID: conversationID))
    }

    @Test("Concurrent attaches for one conversation leave a single subscription")
    func concurrentAttachKeepsOneSubscription() async {
        let hub = ConversationEventsTopicHub()
        let conversationID = UUID()
        let service = TUIRunStreamingService(hub: hub)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await service.attach(conversationID: conversationID, app: makeApp()) }
            }
        }
        #expect(await service.attachedConversationIDs == [conversationID])

        // A leaked duplicate subscription would survive this detach.
        await service.detach(conversationID: conversationID)
        #expect(await !hub.hasSubscribers(forConversationID: conversationID))
    }

    @Test("Detach and detachAll tear down the hub subscriptions")
    func detachTearsDownSubscriptions() async {
        let hub = ConversationEventsTopicHub()
        let first = UUID()
        let second = UUID()
        let service = TUIRunStreamingService(hub: hub)

        await service.attach(conversationID: first, app: makeApp())
        await service.attach(conversationID: second, app: makeApp())
        #expect(await hub.hasSubscribers(forConversationID: first))
        #expect(await hub.hasSubscribers(forConversationID: second))

        await service.detach(conversationID: first)
        #expect(await !hub.hasSubscribers(forConversationID: first))
        #expect(await hub.hasSubscribers(forConversationID: second))

        await service.detachAll()
        #expect(await !hub.hasSubscribers(forConversationID: second))
        #expect(await service.attachedConversationIDs.isEmpty)
    }
}
