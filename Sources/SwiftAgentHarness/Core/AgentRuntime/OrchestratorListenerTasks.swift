import Foundation

struct ConversationListenerTasks: Sendable {
    var agenticLoopListenerTask: Task<Void, Never>?
    var orchestrationSnapshotListenerTask: Task<Void, Never>?

    mutating func cancel() {
        agenticLoopListenerTask?.cancel()
        orchestrationSnapshotListenerTask?.cancel()
        agenticLoopListenerTask = nil
        orchestrationSnapshotListenerTask = nil
    }
}

/// Holds SwiftAgentKit orchestrator background listener tasks keyed by conversation.
struct OrchestratorListenerTasks: Sendable {
    var byConversationID: [UUID: ConversationListenerTasks] = [:]
    var pendingToolCompletionListenerTask: Task<Void, Never>?

    mutating func cancelListeners(for conversationID: UUID) {
        byConversationID[conversationID]?.cancel()
        byConversationID.removeValue(forKey: conversationID)
    }

    mutating func cancelAllListeners() {
        for id in byConversationID.keys {
            byConversationID[id]?.cancel()
        }
        byConversationID.removeAll()
        pendingToolCompletionListenerTask?.cancel()
        pendingToolCompletionListenerTask = nil
    }

    mutating func installListeners(
        for conversationID: UUID,
        agenticLoop: Task<Void, Never>,
        orchestrationSnapshot: Task<Void, Never>
    ) {
        cancelListeners(for: conversationID)
        byConversationID[conversationID] = ConversationListenerTasks(
            agenticLoopListenerTask: agenticLoop,
            orchestrationSnapshotListenerTask: orchestrationSnapshot
        )
    }
}
