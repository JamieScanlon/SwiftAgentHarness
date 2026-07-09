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
    @Test("publishes template summary on loop iteration completed")
    func publishesTemplateSummaryOnIterationCompleted() async {
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
                iteration: 1,
                toolName: "alpha"
            )
        )
        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .toolCallCompleted,
                conversationID: conversationID,
                runID: runID,
                iteration: 1,
                toolName: "beta"
            )
        )
        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .loopIterationCompleted,
                conversationID: conversationID,
                runID: runID,
                iteration: 1
            )
        )

        let payloads = await capture.all()
        #expect(
            payloads.map(\.name) == [
                .turnStarted,
                .toolCallCompleted,
                .toolCallCompleted,
                .toolUsageSummary,
                .loopIterationCompleted,
            ]
        )
        #expect(payloads[3].toolCount == 2)
        #expect(payloads[3].toolNames == ["alpha", "beta"])
        #expect(payloads[3].summaryText == "Ran alpha ×1, beta ×1")
        #expect(payloads[3].source == "runtime.templateLabel")
    }

    @Test("skips summary when iteration had no completed tools")
    func skipsSummaryWithoutTools() async {
        let capture = RuntimeStreamAdapterCapture()
        let conversationID = UUID()
        let runID = UUID()
        let adapter = RuntimeTurnStreamTransportAdapter { payload in
            await capture.append(payload)
        }

        await adapter.consume(
            RuntimeLifecycleEventPayload(
                name: .loopIterationCompleted,
                conversationID: conversationID,
                runID: runID,
                iteration: 1
            )
        )

        let payloads = await capture.all()
        #expect(payloads.map(\.name) == [.loopIterationCompleted])
    }
}
