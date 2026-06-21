import Foundation

enum SubAgentModeProfileConversationPruner {
    static let supportedModeProfileIDs: Set<String> = [
        "memory-extraction",
        "memory-active-recall",
    ]

    struct Candidate: Sendable, Equatable {
        let id: UUID
        let transcriptBytes: Int64
        let messageCount: Int
    }

    struct Report: Sendable, Equatable {
        let modeProfileID: String
        let candidates: [Candidate]
        let deletedCount: Int
        let deletedTranscriptBytes: Int64
    }

    static func listCandidates(
        using persistence: LocalHarnessSessionPersistence,
        modeProfileID: String
    ) throws -> [Candidate] {
        try persistence.listCatalogConversations()
            .filter { $0.modeProfileID == modeProfileID && $0.lineageKind == .subAgent }
            .map { record in
                let url = persistence.transcriptFileURL(conversationID: record.id)
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return Candidate(id: record.id, transcriptBytes: bytes, messageCount: record.messageCount)
            }
            .sorted { $0.transcriptBytes > $1.transcriptBytes }
    }

    static func prune(
        using persistence: LocalHarnessSessionPersistence,
        modeProfileID: String,
        execute: Bool
    ) throws -> Report {
        let candidates = try listCandidates(using: persistence, modeProfileID: modeProfileID)
        guard execute else {
            return Report(modeProfileID: modeProfileID, candidates: candidates, deletedCount: 0, deletedTranscriptBytes: 0)
        }
        var deletedCount = 0
        var deletedTranscriptBytes: Int64 = 0
        for candidate in candidates {
            try persistence.removeSessionConversation(conversationID: candidate.id)
            _ = AgentPlanStore.removeConversationDirectory(for: candidate.id)
            deletedCount += 1
            deletedTranscriptBytes += candidate.transcriptBytes
        }
        if deletedCount > 0 {
            try persistence.vacuumCatalog()
        }
        return Report(
            modeProfileID: modeProfileID,
            candidates: candidates,
            deletedCount: deletedCount,
            deletedTranscriptBytes: deletedTranscriptBytes
        )
    }
}
