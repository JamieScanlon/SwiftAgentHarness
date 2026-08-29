import EasyJSON
import Foundation

public enum ConversationLineageInference {
    /// Mode profiles used for machine-spawned sub-agents (least-privilege tool surfaces).
    public static let machineSubAgentModeProfileIDs: Set<String> = [
        "subagent-minimal",
        "subagent-explore",
        "subagent-plan",
        "subagent-general",
        "memory-extraction",
        "memory-active-recall",
        "memory-pre-compaction-flush",
        "trigger-delegate",
    ]

    public static let memoryWriteScopedModeProfileIDs: Set<String> = [
        "memory-extraction",
        "memory-pre-compaction-flush",
    ]

    public static func isMemoryWriteScopedProfile(_ modeProfileID: String?) -> Bool {
        guard let raw = modeProfileID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        return memoryWriteScopedModeProfileIDs.contains(raw)
    }

    /// Backfill / migration inference from legacy catalog fields.
    public static func infer(
        metadataJSON: String?,
        interactionModeRaw: String,
        modeProfileID: String?,
        topic: String?,
        parentConversationID: UUID?,
        forkAnchorEntryID: String?
    ) -> (lineage: ConversationLineageKind, origin: ConversationOrigin) {
        let metadata = metadataJSON.flatMap { try? JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
        if hasSubAgentDepth(metadata) {
            return (.subAgent, .system)
        }
        let mode = interactionModeRaw.lowercased()
        let topicLower = topic?.lowercased() ?? ""
        if mode.hasPrefix("memory-") || topicLower.hasPrefix("memory-") {
            return (.subAgent, .system)
        }
        if isMachineSubAgentProfile(modeProfileID) || mode == "trigger-delegate" || topicLower == "trigger-delegate" {
            return (.subAgent, .system)
        }
        if hasTriggerHost(metadata) {
            return (.root, .system)
        }
        if parentConversationID != nil || forkAnchorEntryID != nil {
            return (.branch, .user)
        }
        return (.root, .user)
    }

    private static func isMachineSubAgentProfile(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return machineSubAgentModeProfileIDs.contains(normalized)
    }

    private static func hasSubAgentDepth(_ metadata: JSON?) -> Bool {
        guard case .object(let object) = metadata else { return false }
        return object["subAgentDepth"] != nil
    }

    private static func hasTriggerHost(_ metadata: JSON?) -> Bool {
        guard case .object(let object) = metadata else { return false }
        return object["triggerHost"] != nil
    }
}
