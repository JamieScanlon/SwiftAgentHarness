import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

enum RecordedConversationStreamAction: Sendable, Equatable {
    case ingest(ChatStreamingPartial)
    case flushSegment
    case finish(StreamingFinalPayload)
    case cancel
}

actor RecordingConversationStreamConsumer: ConversationStreamConsumer {
    private(set) var actions: [RecordedConversationStreamAction] = []

    func ingest(_ partial: ChatStreamingPartial) async {
        actions.append(.ingest(partial))
    }

    func flushSegment() async {
        actions.append(.flushSegment)
    }

    func finishTurn(final: StreamingFinalPayload) async {
        actions.append(.finish(final))
    }

    func cancelTurn() async {
        actions.append(.cancel)
    }

    func reset() {
        actions = []
    }
}

@Suite("ConversationStreamSurfaceDriver")
struct ConversationStreamSurfaceDriverTests {
    private func lifecycle(
        _ name: RuntimeLifecycleEventName,
        conversationID: UUID,
        runID: UUID
    ) -> DecodedConversationTopicEvent {
        .runtimeLifecycle(
            RuntimeLifecycleEventPayload(
                name: name,
                conversationID: conversationID,
                runID: runID,
                source: "tests"
            ),
            seq: nil,
            turnOrdinal: nil
        )
    }

    @Test("streamDone flushes segment without finalizing")
    func streamDoneDoesNotFinalize() async {
        let driver = ConversationStreamSurfaceDriver()
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()

        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(.partial(.text("partial"), runID: runID, callID: nil, seq: 1, turnOrdinal: 1), consumer: consumer)
        await driver.handle(.streamDone(runID: runID, seq: 2, turnOrdinal: 2), consumer: consumer)

        let actions = await consumer.actions
        #expect(actions.contains(.ingest(.text("partial"))))
        #expect(actions.contains(.flushSegment))
        #expect(!actions.contains(where: { if case .finish = $0 { return true }; return false }))
    }

    @Test("Finalizes from committed messagesRefresh on turn.completed")
    func finalFromCommittedRow() async {
        let driver = ConversationStreamSurfaceDriver()
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()
        let assistant = Message(id: UUID(), role: .assistant, content: "canonical answer")

        await driver.handle(.committedMessages([], seq: 0, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(.partial(.text("live delta"), runID: runID, callID: nil, seq: 1, turnOrdinal: 1), consumer: consumer)
        await driver.handle(.committedMessages([assistant], seq: 2, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnCompleted, conversationID: cid, runID: runID), consumer: consumer)

        let actions = await consumer.actions
        let finishActions = actions.compactMap { action -> StreamingFinalPayload? in
            if case .finish(let payload) = action { return payload }
            return nil
        }
        #expect(finishActions.count == 1)
        #expect(finishActions[0].text == "canonical answer")
        #expect(finishActions[0].text != "live delta")
    }

    @Test("Waits for messagesRefresh when turn.completed arrives first")
    func commitRaceWait() async {
        let driver = ConversationStreamSurfaceDriver(configuration: .init(commitWaitTimeoutMs: 300))
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()
        let assistant = Message(id: UUID(), role: .assistant, content: "late commit")

        await driver.handle(.committedMessages([], seq: 0, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)

        let finalizeTask = Task {
            await driver.handle(lifecycle(.turnCompleted, conversationID: cid, runID: runID), consumer: consumer)
        }

        try? await Task.sleep(for: .milliseconds(50))
        await driver.handle(.committedMessages([assistant], seq: 1, turnOrdinal: nil), consumer: consumer)
        await finalizeTask.value

        let actions = await consumer.actions
        #expect(actions.contains(.finish(StreamingFinalPayload(text: "late commit"))))
    }

    @Test("turn.cancelled invokes cancelTurn")
    func cancelledTurn() async {
        let driver = ConversationStreamSurfaceDriver()
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()

        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(lifecycle(.turnCancelled, conversationID: cid, runID: runID), consumer: consumer)

        let actions = await consumer.actions
        #expect(actions.contains(.cancel))
    }

    @Test("Multi-message turn dedups delivered message ids")
    func multiMessageDedup() async {
        let driver = ConversationStreamSurfaceDriver()
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()
        let block1 = Message(id: UUID(), role: .assistant, content: "block one")
        let block2 = Message(id: UUID(), role: .assistant, content: "block two")

        await driver.handle(.committedMessages([], seq: 0, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(.committedMessages([block1], seq: 1, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnCompleted, conversationID: cid, runID: runID), consumer: consumer)

        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(.committedMessages([block1, block2], seq: 2, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnCompleted, conversationID: cid, runID: runID), consumer: consumer)

        let actions = await consumer.actions
        let finishTexts = actions.compactMap { action -> String? in
            if case .finish(let payload) = action { return payload.text }
            return nil
        }
        #expect(finishTexts == ["block one", "block two"])
    }

    @Test("turn.bounded finalizes with notice")
    func boundedTurn() async {
        let driver = ConversationStreamSurfaceDriver(
            configuration: .init(boundedTurnNotice: "bounded")
        )
        let consumer = RecordingConversationStreamConsumer()
        let cid = UUID()
        let runID = UUID()
        let assistant = Message(id: UUID(), role: .assistant, content: "partial output")

        await driver.handle(.committedMessages([], seq: 0, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnStarted, conversationID: cid, runID: runID), consumer: consumer)
        await driver.handle(.committedMessages([assistant], seq: 1, turnOrdinal: nil), consumer: consumer)
        await driver.handle(lifecycle(.turnBounded, conversationID: cid, runID: runID), consumer: consumer)

        let actions = await consumer.actions
        let finishTexts = actions.compactMap { action -> String? in
            if case .finish(let payload) = action { return payload.text }
            return nil
        }
        #expect(finishTexts.count == 1)
        #expect(finishTexts[0].contains("partial output"))
        #expect(finishTexts[0].contains("bounded"))
    }
}
