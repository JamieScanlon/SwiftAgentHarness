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
}
