import Foundation

struct SubAgentDelegateEventTranslationResult: Sendable {
    var lifecycleEntry: SubAgentLifecycleEntryPayload
    var runtimeLifecycleEvent: RuntimeLifecycleEventPayload?
}

struct SubAgentDelegateEventTranslator: Sendable {
    func translate(
        event: SubAgentDelegateEvent,
        existingEntry: SubAgentLifecycleEntryPayload?
    ) -> SubAgentDelegateEventTranslationResult {
        let phase = lifecyclePhase(for: event.phase)
        let lifecycleEntry = SubAgentLifecycleEntryPayload(
            lifecycleID: event.lifecycleID,
            parentConversationID: event.parentConversationID,
            childConversationID: event.childConversationID ?? existingEntry?.childConversationID,
            delegateToolName: event.delegateToolName ?? existingEntry?.delegateToolName,
            asyncHandleID: event.asyncHandleID ?? existingEntry?.asyncHandleID,
            phase: phase,
            eventTrustLevel: event.eventTrustLevel,
            defaultTrustLevel: resolvedDefaultTrustLevel(event: event, existingEntry: existingEntry),
            permissionPolicy: event.permissionPolicy ?? existingEntry?.permissionPolicy,
            approvalRoute: event.approvalRoute ?? existingEntry?.approvalRoute,
            completionAnnounceID: event.completionAnnounceID ?? existingEntry?.completionAnnounceID,
            toolCallID: event.toolCallID ?? existingEntry?.toolCallID,
            completionSource: event.completionSource ?? existingEntry?.completionSource,
            completionUsage: resolvedCompletionUsage(event: event, existingEntry: existingEntry, phase: phase),
            error: event.error ?? existingEntry?.error,
            updatedAt: event.updatedAt
        )
        return SubAgentDelegateEventTranslationResult(
            lifecycleEntry: lifecycleEntry,
            runtimeLifecycleEvent: event.runtimeLifecycleEvent
        )
    }

    private func lifecyclePhase(for phase: SubAgentDelegateEventPhase) -> SubAgentLifecyclePhase {
        switch phase {
        case .queued: .queued
        case .dispatching: .dispatching
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .completing: .completing
        case .done: .done
        case .failed: .failed
        case .orphaned: .orphaned
        }
    }

    private func resolvedCompletionUsage(
        event: SubAgentDelegateEvent,
        existingEntry: SubAgentLifecycleEntryPayload?,
        phase: SubAgentLifecyclePhase
    ) -> SubAgentDelegateCompletionUsage? {
        guard phase == .done else { return nil }
        return event.completionUsage ?? existingEntry?.completionUsage
    }

    private func resolvedDefaultTrustLevel(
        event: SubAgentDelegateEvent,
        existingEntry: SubAgentLifecycleEntryPayload?
    ) -> String? {
        if let eventTrustLevel = event.eventTrustLevel,
           !eventTrustLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return eventTrustLevel
        }
        if let defaultTrustLevel = event.defaultTrustLevel,
           !defaultTrustLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultTrustLevel
        }
        return existingEntry?.defaultTrustLevel
    }
}
