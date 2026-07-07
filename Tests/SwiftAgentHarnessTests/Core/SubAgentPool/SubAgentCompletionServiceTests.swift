import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgent completion service")
struct SubAgentCompletionServiceTests {
    @Test("registerHandleOwnership resolves completion and session handles")
    func registerHandleOwnershipResolves() async {
        let service = SubAgentCompletionService()
        let conversationID = UUID()
        await service.registerHandleOwnership(
            conversationID: conversationID,
            sessionHandleID: "session-1",
            completionHandleID: "completion-1"
        )

        let byCompletion = await service.resolveConversationIDForHandle(
            handleID: "completion-1",
            fallbackSessionHandleID: nil
        )
        let bySession = await service.resolveConversationIDForHandle(
            handleID: "unknown",
            fallbackSessionHandleID: "session-1"
        )
        #expect(byCompletion == conversationID)
        #expect(bySession == conversationID)
    }

    @Test("delivery state transitions keep dedupe semantics")
    func deliveryStateTransitions() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-1",
            toolCallID: "tool-call-1",
            conversationID: UUID(),
            lifecycleID: "lifecycle-1",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == false)
        await service.markPending(payload)
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == false)
        await service.markDelivered(payload)
        #expect(await service.hasDelivered(delegateHandleID: payload.delegateHandleID, toolCallID: payload.toolCallID) == true)
    }

    @Test("tryBeginDelivery allows only one concurrent reservation per correlation key")
    func tryBeginDeliveryConcurrentReservation() async {
        let service = SubAgentCompletionService()
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                await service.tryBeginDelivery(delegateHandleID: "handle-a", toolCallID: "tool-a")
            }
            group.addTask {
                await service.tryBeginDelivery(delegateHandleID: "handle-a", toolCallID: "tool-a")
            }
            var collected: [Bool] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(results.filter { !$0 }.count == 1)
    }

    @Test("tryBeginDelivery can re-acquire after markPending")
    func tryBeginDeliveryAfterMarkPending() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-retry",
            toolCallID: "tool-retry",
            conversationID: UUID(),
            lifecycleID: "lifecycle-retry",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
        await service.markPending(payload)
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
    }

    @Test("tryBeginDelivery rejects after markDelivered")
    func tryBeginDeliveryAfterMarkDelivered() async {
        let service = SubAgentCompletionService()
        let payload = CompletionAnnouncePayload(
            delegateHandleID: "delegate-delivered",
            toolCallID: "tool-delivered",
            conversationID: UUID(),
            lifecycleID: "lifecycle-delivered",
            status: .done,
            completedAt: Date(),
            source: "test"
        )
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == true)
        await service.markDelivered(payload)
        #expect(await service.tryBeginDelivery(
            delegateHandleID: payload.delegateHandleID,
            toolCallID: payload.toolCallID
        ) == false)
    }
}
