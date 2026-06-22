import Foundation

/// Per-conversation compaction mutex (harness “compaction lock”): only one compaction LLM run may be in-flight
/// per conversation. When unavailable, callers should continue with the current transcript / checkpoints without blocking.
public actor CompactionConcurrencyCoordinator {
    public init() {}
    private var activeConversationIDs: Set<UUID> = []

    /// Returns true if this conversation was not already locked (caller must ``release``).
    public func tryAcquire(for conversationID: UUID) -> Bool {
        if activeConversationIDs.contains(conversationID) {
            return false
        }
        activeConversationIDs.insert(conversationID)
        return true
    }

    public func release(for conversationID: UUID) {
        activeConversationIDs.remove(conversationID)
    }
}
