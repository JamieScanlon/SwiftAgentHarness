import Foundation
import Testing
@testable import SwiftAgentHarness

private actor RuntimeStreamAdapterCapture {
    private(set) var payloads: [RuntimeLifecycleEventPayload] = []

    func append(_ payload: RuntimeLifecycleEventPayload) {
        payloads.append(payload)
    }

    func all() -> [RuntimeLifecycleEventPayload] {
        payloads
    }
}

@Suite("Runtime turn stream transport adapter")
struct RuntimeTurnStreamTransportAdapterTests {
    @Test("publishes input events and emits tool usage summary after stream end")
    func publishesEventsAndSummary() async {
        let capture = RuntimeStreamAdapterCapture()
        let conversationID = UUID()
        let runID = UUID()
        let adapter = RuntimeTurnStreamTransportAdapter { payload in
            await capture.append(payload)
        }

        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .turnStarted,
                conversationID: conversationID,
                runID: runID
            )
        )
        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .toolCallCompleted,
                conversationID: conversationID,
                runID: runID,
                toolName: "tool_alpha"
            )
        )
        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .toolCallCompleted,
                conversationID: conversationID,
                runID: runID,
                toolName: "tool_beta"
            )
        )
        await adapter.publishToolUsageSummaryIfNeeded(conversationID: conversationID, runID: runID)

        let payloads = await capture.all()
        #expect(payloads.map(\.name) == [.turnStarted, .toolCallCompleted, .toolCallCompleted, .toolUsageSummary])
        #expect(payloads.last?.toolCount == 2)
        #expect(payloads.last?.toolNames == ["tool_alpha", "tool_beta"])
    }
}
