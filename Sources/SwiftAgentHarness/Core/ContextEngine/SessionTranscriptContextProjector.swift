import CryptoKit
import Foundation
import SwiftAgentKit

enum SessionTranscriptContextProjector: Sendable {
    static func projectMessages(
        entries: [SessionTranscriptEntry],
        fallbackMessages: [Message]
    ) -> [Message] {
        guard !entries.isEmpty else { return fallbackMessages }
        var projected: [Message] = []
        var pendingCompactionSummary: String?
        var keptFromFirstEntry = false
        var firstKeptEntryID: SessionEntryID?
        for entry in entries {
            switch entry.type {
            case .compaction:
                if let wire = try? SessionTranscriptPayloadAllowlist.decodeCompactionCheckpointPayload(entry.payloadJSON) {
                    pendingCompactionSummary = wire.summary
                    firstKeptEntryID = wire.firstKeptEntryID
                    keptFromFirstEntry = false
                }
            case .branchSummary:
                if let wire = try? SessionTranscriptPayloadAllowlist.decodeBranchSummaryPayload(entry.payloadJSON) {
                    pendingCompactionSummary = wire.summary
                    firstKeptEntryID = wire.fromEntryID
                    keptFromFirstEntry = false
                }
            case .system:
                // Always replay the conversation's system prompt, regardless of the compaction
                // anchor, so the projected head is never left without system framing.
                if let message = try? SessionTranscriptMapping.messageForReplay(from: entry) {
                    projected.append(message)
                }
            case .message:
                if let target = firstKeptEntryID, !keptFromFirstEntry {
                    if entry.entryId == target {
                        keptFromFirstEntry = true
                    } else {
                        continue
                    }
                }
                if let summary = pendingCompactionSummary {
                    projected.append(
                        Message(
                            id: stableSummaryMessageID(entryID: entry.entryId, summary: summary),
                            role: .system,
                            content: summary,
                            timestamp: entry.timestamp,
                            toolCalls: []
                        )
                    )
                    pendingCompactionSummary = nil
                    firstKeptEntryID = nil
                }
                if let message = try? SessionTranscriptMapping.messageForReplay(from: entry) {
                    projected.append(message)
                }
            default:
                continue
            }
        }
        if let summary = pendingCompactionSummary {
            let anchor = firstKeptEntryID ?? SessionEntryID(rawValue: "00000000")
            projected.append(
                Message(
                    id: stableSummaryMessageID(entryID: anchor, summary: summary),
                    role: .system,
                    content: summary,
                    timestamp: Date(),
                    toolCalls: []
                )
            )
        }
        let result = projected.isEmpty ? fallbackMessages : projected
        // Never begin a kept region on an orphaned tool result (assistant tool-call trimmed).
        return RenderableMessageInvariant.repairToolPairs(result)
    }

    private static func stableSummaryMessageID(entryID: SessionEntryID, summary: String) -> UUID {
        let seed = "compaction-summary:\(entryID.rawValue):\(summary.prefix(64))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
