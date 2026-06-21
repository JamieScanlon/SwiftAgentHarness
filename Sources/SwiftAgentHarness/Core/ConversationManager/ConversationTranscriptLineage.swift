import Foundation
import SwiftAgentKit

enum ConversationTranscriptLineage {
    /// Resolves catalog head, falling back to the max-sequence transcript entry when head is unset (migration).
    static func resolvedHeadEntryId(
        conversationID: UUID,
        harness: any HarnessSessionPersistence
    ) throws -> SessionEntryID? {
        let entries = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        let byId = [SessionEntryID: SessionTranscriptEntry](uniqueKeysWithValues: entries.map { ($0.entryId, $0) })
        if let head = try harness.activeHeadEntryId(conversationID: conversationID),
           let messageHead = messageSystemHead(from: head, entryById: byId) {
            return messageHead
        }
        return entries
            .filter { $0.type == .message || $0.type == .system }
            .max(by: { $0.sequence < $1.sequence })?
            .entryId
    }

    /// Catalog head may point at a journal/aux row; active branch tip is the nearest message/system ancestor.
    private static func messageSystemHead(
        from head: SessionEntryID,
        entryById: [SessionEntryID: SessionTranscriptEntry]
    ) -> SessionEntryID? {
        var current: SessionEntryID? = head
        var seen = Set<SessionEntryID>()
        var depth = 0
        while let id = current, depth < 4096 {
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            guard let entry = entryById[id] else { return nil }
            if entry.type == .message || entry.type == .system {
                return id
            }
            current = entry.parentEntryId
            depth += 1
        }
        return nil
    }

    /// Active branch entries root → leaf.
    static func activeLineageEntries(
        conversationID: UUID,
        harness: any HarnessSessionPersistence
    ) throws -> [SessionTranscriptEntry] {
        guard let head = try resolvedHeadEntryId(conversationID: conversationID, harness: harness) else {
            return []
        }
        return (try? harness.readLineage(conversationID: conversationID, leafEntryId: head)) ?? []
    }

    /// Maps lineage message/system rows to domain messages from transcript replay.
    static func activeMessages(
        conversationID: UUID,
        harness: any HarnessSessionPersistence
    ) throws -> [Message] {
        let fromLineage = messagesFromLineageEntries(
            try activeLineageEntries(conversationID: conversationID, harness: harness)
        )
        if !fromLineage.isEmpty {
            return fromLineage
        }
        let all = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        return messagesFromLinearSequenceReplay(all)
    }

    private static func messagesFromLineageEntries(_ lineage: [SessionTranscriptEntry]) -> [Message] {
        var out: [Message] = []
        out.reserveCapacity(lineage.count)
        for entry in lineage where entry.type == .message || entry.type == .system {
            guard let message = try? SessionTranscriptMapping.messageForReplay(from: entry) else { continue }
            out.append(message)
        }
        return out
    }

    /// When branch head resolution yields no lineage, replay message/system rows in sequence order.
    private static func messagesFromLinearSequenceReplay(_ entries: [SessionTranscriptEntry]) -> [Message] {
        let sorted = entries
            .filter { $0.type == .message || $0.type == .system }
            .sorted { $0.sequence < $1.sequence }
        return messagesFromLineageEntries(sorted)
    }

    static func harnessTailMessageID(
        conversationID: UUID,
        harness: any HarnessSessionPersistence
    ) throws -> UUID? {
        let lineage = try activeLineageEntries(conversationID: conversationID, harness: harness)
        for entry in lineage.reversed() where entry.type == .message || entry.type == .system {
            if let message = try? SessionTranscriptMapping.messageForReplay(from: entry) {
                return message.id
            }
        }
        return nil
    }
}
