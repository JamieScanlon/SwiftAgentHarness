//
//  Physical removal of superseded derived-journal transcript rows (invalidation-floor driven).
//

import Foundation

enum TranscriptJournalRetentionPruner {
    private static let maxDeletesPerConversation = 2048

    static func pruneConversation(
        conversationID: UUID,
        harness: any HarnessSessionPersistence,
        policy: DerivedArtifactRetentionPolicy
    ) throws -> (deletedDerived: Int, deletedSnapshots: Int) {
        guard policy.supersededOnly else { return (0, 0) }
        let lock = try harness.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }

        let entries = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        let (events, _) = SessionTranscriptV2JournalMapping.cachedEvents(from: entries, conversationID: conversationID)
        let floorMap = DerivedArtifactContractMatrix.invalidationFloorMapForRetention(events: events)
        let snapshotFloor = DerivedArtifactContractMatrix.snapshotSupersessionFloor(events: events)

        var deletedDerived = 0
        var deletedSnapshots = 0
        var kept: [SessionTranscriptEntry] = []
        kept.reserveCapacity(entries.count)

        for entry in entries {
            if let drop = dropReason(
                entry: entry,
                floorMap: floorMap,
                snapshotFloor: snapshotFloor,
                deletedDerived: deletedDerived,
                deletedSnapshots: deletedSnapshots
            ) {
                switch drop {
                case .derived: deletedDerived += 1
                case .snapshot: deletedSnapshots += 1
                }
                continue
            }
            kept.append(entry)
        }

        guard deletedDerived > 0 || deletedSnapshots > 0 else { return (0, 0) }
        try persistRewrittenEntries(conversationID: conversationID, harness: harness, entries: kept)
        return (deletedDerived, deletedSnapshots)
    }

    private enum DropKind {
        case derived
        case snapshot
    }

    private static func dropReason(
        entry: SessionTranscriptEntry,
        floorMap: [String: Int],
        snapshotFloor: Int,
        deletedDerived: Int,
        deletedSnapshots: Int
    ) -> DropKind? {
        guard deletedDerived + deletedSnapshots < maxDeletesPerConversation else { return nil }
        switch entry.type {
        case .derivedJournal:
            guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON) else {
                return nil
            }
            if let contract = DerivedArtifactContractMatrix.contract(forPersistedKind: env.kind),
               contract.retentionEligible {
                let floor = floorMap[env.kind] ?? 0
                if env.eventID <= floor { return .derived }
            }
            if env.kind == ConversationEventKind.compactionApplied.rawValue,
               let payload = ConversationEventCodec.decode(CompactionAppliedEventPayload.self, from: env.innerPayloadJSON),
               payload.uptoEventID <= snapshotFloor {
                return .snapshot
            }
            return nil
        case .compaction:
            if snapshotFloor > 0,
               let payload = ConversationEventCodec.decode(CompactionAppliedEventPayload.self, from: entry.payloadJSON),
               payload.uptoEventID <= snapshotFloor {
                return .snapshot
            }
            return nil
        default:
            return nil
        }
    }

    private static func persistRewrittenEntries(
        conversationID: UUID,
        harness: any HarnessSessionPersistence,
        entries: [SessionTranscriptEntry]
    ) throws {
        if let local = harness as? LocalHarnessSessionPersistence {
            let url = local.transcriptFileURL(conversationID: conversationID)
            let parsed = try SessionJSONLTranscriptReader.loadParsed(fileURL: url)
            try SessionJSONLTranscriptWriter.rewriteTranscript(
                fileURL: url,
                parsed: ParsedTranscriptFile(header: parsed.header, entries: entries)
            )
            _ = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
            TranscriptJournalTailCache.invalidate(conversationID: conversationID)
            return
        }
        if let memory = harness as? InMemoryHarnessSessionPersistence {
            try memory.replaceTranscriptBody(conversationID: conversationID, entries: entries)
            return
        }
    }
}
