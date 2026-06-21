import Foundation

/// Partition of `conversation/{id}/events` payloads for replay and sequencing (P2).
enum ConversationEventsReplayClassifier {
    enum Stream: Sendable {
        /// Durable transcript rows surfaced on the message replay cursor (`sinceMessageSeq`).
        case persistedMessage
        /// Durable transcript rows surfaced on the checkpoint replay cursor (`sinceCheckpointSeq`).
        case persistedCheckpoint
        /// Ephemeral traffic (`runId` + `turnOrdinal`); not in `readTranscriptEntries` replay.
        case transient
    }

    static func stream(for payload: ConversationTopicEventPayload) -> Stream {
        switch payload.semanticKind {
        case .messagesRefresh:
            return .persistedMessage
        case .checkpoint:
            return .persistedCheckpoint
        case .contentDelta, .streamDone, .modelLifecycle, .runtimeLifecycle, .surfaceIntent:
            return .transient
        }
    }

    static func isPersistedMessageStream(entry: SessionTranscriptEntry) -> Bool {
        switch entry.type {
        case .message, .system, .modelChange, .thinkingLevelChange, .custom:
            return true
        case .compaction, .branchSummary, .conversationJournal, .derivedJournal:
            return false
        }
    }

    /// Kinds surfaced on the checkpoint replay cursor when stored as ``SessionTranscriptEntryType/derivedJournal``.
    private static let derivedCheckpointJournalKinds: Set<String> = [
        ConversationEventKind.contextCompactionCheckpoint.rawValue,
        ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
        ConversationEventKind.toolResultTrimCheckpoint.rawValue,
        ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
        ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
        ConversationEventKind.compactionApplied.rawValue,
        ConversationEventKind.checkpointInvalidated.rawValue,
    ]

    static func isPersistedCheckpointStream(entry: SessionTranscriptEntry) -> Bool {
        if entry.type == .compaction || entry.type == .branchSummary { return true }
        if entry.type == .derivedJournal {
            guard let env = try? SessionTranscriptJournalEnvelopeCodec.decode(entry.payloadJSON) else {
                return false
            }
            return derivedCheckpointJournalKinds.contains(env.kind)
        }
        return false
    }
}
