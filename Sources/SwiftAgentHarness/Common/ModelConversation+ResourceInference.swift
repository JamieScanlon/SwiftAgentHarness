import Foundation

extension ModelConversation {
    /// Maps streaming/orchestration/UI fields into harness ``ConversationResourceRunStatus`` for persistence.
    ///
    /// **Mapping:** `.errored` when ``showError`` is true or agentic phase is `.failed` / `.maxIterationsReached`.
    /// `.running` when ``ModelState`` is `.generating`/`.loading`, else non-terminal agentic phases (anything other than `.idle`/`.completed`).
    /// `.idle` otherwise. ``ConversationResourceRunStatus/awaitingApproval`` is reserved for future approval gates.
    /// Persisted run ids use ``HarnessRuntimeSession``'s `runtimeLifecycle.currentStreamingRunID` during streaming.
    public func inferredResourceRunStatusForPersistence() -> ConversationResourceRunStatus {
        if agenticPhase == .failed || agenticPhase == .maxIterationsReached {
            return .errored
        }
        switch state {
        case .generating, .loading:
            return .running
        case .idle:
            break
        }
        switch agenticPhase {
        case .idle, .completed:
            return .idle
        default:
            return .running
        }
    }
}
