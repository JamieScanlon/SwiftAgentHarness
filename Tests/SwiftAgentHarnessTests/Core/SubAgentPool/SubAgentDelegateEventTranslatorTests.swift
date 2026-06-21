import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentDelegateEventTranslator")
struct SubAgentDelegateEventTranslatorTests {
    let translator = SubAgentDelegateEventTranslator()

    @Test("failed phase clears inherited completion usage")
    func failedClearsCompletionUsage() {
        let parentID = UUID()
        let existing = SubAgentLifecycleEntryPayload(
            lifecycleID: "l-1",
            parentConversationID: parentID,
            phase: .running,
            completionUsage: DelegateCompletionUsagePayload(costUSD: 0.12)
        )
        let event = SubAgentDelegateEvent(
            lifecycleID: "l-1",
            parentConversationID: parentID,
            phase: .failed,
            error: "cancelled_by_operator"
        )
        let translated = translator.translate(event: event, existingEntry: existing)
        #expect(translated.lifecycleEntry.phase == .failed)
        #expect(translated.lifecycleEntry.completionUsage == nil)
    }

    @Test("orphaned phase clears inherited completion usage")
    func orphanedClearsCompletionUsage() {
        let parentID = UUID()
        let childID = UUID()
        let existing = SubAgentLifecycleEntryPayload(
            lifecycleID: "l-2",
            parentConversationID: parentID,
            childConversationID: childID,
            phase: .completing,
            completionUsage: DelegateCompletionUsagePayload(totalTokens: 42)
        )
        let event = SubAgentDelegateEvent(
            lifecycleID: "l-2",
            parentConversationID: parentID,
            childConversationID: childID,
            phase: .orphaned,
            error: "gateway_restart_orphan",
            runtimeLifecycleEvent: RuntimeLifecycleEventPayload(
                name: .subagentOrphaned,
                conversationID: parentID,
                childConversationID: childID,
                source: "subagent.pool.orphan"
            )
        )
        let translated = translator.translate(event: event, existingEntry: existing)
        #expect(translated.lifecycleEntry.phase == .orphaned)
        #expect(translated.lifecycleEntry.completionUsage == nil)
        #expect(translated.runtimeLifecycleEvent?.name == .subagentOrphaned)
    }

    @Test("done phase preserves completion usage")
    func donePreservesCompletionUsage() {
        let parentID = UUID()
        let usage = DelegateCompletionUsagePayload(costUSD: 0.03)
        let event = SubAgentDelegateEvent(
            lifecycleID: "l-3",
            parentConversationID: parentID,
            phase: .done,
            completionUsage: usage
        )
        let translated = translator.translate(event: event, existingEntry: nil)
        #expect(translated.lifecycleEntry.completionUsage == usage)
    }
}
