import Foundation

/// Kernel gate for TurnLoop blocking active-memory recall.
///
/// **Lineage-only by design.** Eligibility is expressed in terms of conversation lineage
/// (sub-agent, machine profiles, memory-* modes/topics). Do not add Memory-layer rules
/// here — e.g. ``MemoryChatType/direct`` is enforced in Memory (`commonGatesPass`, runner).
///
/// Two overloads, deliberately different strictness:
/// - ``shouldRunBlockingPreReplyRecall(for:)`` — authoritative front gate (TurnLoop). Checks
///   lineage kind, machine sub-agent profiles, and memory-* interaction modes/topics.
/// - ``shouldRunBlockingPreReplyRecall(scope:)`` — optional backstop when
///   ``ConversationScope/current`` is set during a child run; only rejects sub-agents.
///   Never use the scope overload as the sole guard.
public enum ConversationActiveMemoryPolicy {
    public static func shouldRunBlockingPreReplyRecall(scope: ConversationScope) -> Bool {
        guard !scope.isSubAgent else { return false }
        return true
    }

    public static func shouldRunBlockingPreReplyRecall(for conversation: ModelConversation) -> Bool {
        guard conversation.lineageKind != .subAgent else { return false }
        if isMachineSubAgentProfile(conversation.modeProfileID) {
            return false
        }
        let mode = conversation.interactionMode.rawValue.lowercased()
        if mode.hasPrefix("memory-") {
            return false
        }
        if conversation.topic?.lowercased().hasPrefix("memory-") == true {
            return false
        }
        return true
    }

    private static func isMachineSubAgentProfile(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return ConversationLineageInference.machineSubAgentModeProfileIDs.contains(normalized)
    }
}
