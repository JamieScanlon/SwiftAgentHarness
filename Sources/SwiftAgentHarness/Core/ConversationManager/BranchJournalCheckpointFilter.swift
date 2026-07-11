import Foundation

/// Per-kind checkpoint/summary admissibility for branch inheritance.
enum BranchJournalCheckpointFilter {
    static func isDurableHarnessCheckpointKind(_ kind: String) -> Bool {
        DerivedArtifactContractMatrix.branchInheritanceRule(forPersistedKind: kind) == .durableCheckpointScoped
    }

    static func isTurnSummaryKind(_ kind: String) -> Bool {
        DerivedArtifactContractMatrix.branchInheritanceRule(forPersistedKind: kind) == .turnSummaryScoped
    }

    /// When false, the checkpoint event is omitted from the fork (references messages outside the inherited prefix).
    static func shouldCopyCheckpointEvent(
        _ event: CachedConversationEvent,
        allowedMessageIDs: Set<UUID>,
        allowSystemPromptAssemblyCheckpoint: Bool = true
    ) -> Bool {
        switch event.kind {
        case ConversationEventKind.contextCompactionCheckpoint.rawValue:
            guard let p = ConversationEventCodec.decode(ContextCompactionCheckpointPayload.self, from: event.payloadJSON) else {
                return false
            }
            guard !p.coveredMessageIDs.isEmpty,
                  p.syntheticMessages.count == p.coveredMessageIDs.count,
                  Set(p.coveredMessageIDs).isSubset(of: allowedMessageIDs)
            else {
                return false
            }
            if let tail = p.basedOnTailMessageID,
               tail != p.coveredMessageIDs.last {
                return false
            }
            return true
        case ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue:
            guard let w = ConversationEventCodec.decode(MemoryInjectionSnapshotCheckpointWire.self, from: event.payloadJSON) else {
                return false
            }
            if let prefix = MemoryInjectionSnapshotProjectionPolicy.resolvedSelectionContextPrefix(from: w) {
                guard !prefix.isEmpty else { return false }
                return Set(prefix).isSubset(of: allowedMessageIDs)
            }
            guard !w.scopeMessageIDs.isEmpty else { return false }
            return Set(w.scopeMessageIDs).isSubset(of: allowedMessageIDs)
        case ConversationEventKind.toolResultTrimCheckpoint.rawValue:
            guard let w = ConversationEventCodec.decode(ToolResultTrimCheckpointWire.self, from: event.payloadJSON) else {
                return false
            }
            guard !w.coveredMessageIDs.isEmpty, !w.trimmedToolCallIds.isEmpty else { return false }
            return Set(w.coveredMessageIDs).isSubset(of: allowedMessageIDs)
        case ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue:
            guard allowSystemPromptAssemblyCheckpoint,
                  let w = ConversationEventCodec.decode(SystemPromptAssemblyCheckpointWire.self, from: event.payloadJSON),
                  !w.assemblyFingerprint.isEmpty
            else {
                return false
            }
            return true
        case ConversationEventKind.attachmentProjectionCheckpoint.rawValue:
            guard let w = ConversationEventCodec.decode(AttachmentProjectionCheckpointWire.self, from: event.payloadJSON) else {
                return false
            }
            return !w.projectionFingerprint.isEmpty && !w.decisions.isEmpty
        default:
            return false
        }
    }

    static func shouldCopyTurnSummaryEvent(
        _ event: CachedConversationEvent,
        allowedMessageIDs: Set<UUID>
    ) -> Bool {
        guard let payload = ConversationEventCodec.decode(SummaryCreatedEventPayload.self, from: event.payloadJSON) else {
            return false
        }
        guard !payload.coveredMessageIDs.isEmpty else { return false }
        guard Set(payload.coveredMessageIDs).isSubset(of: allowedMessageIDs) else { return false }
        if let tail = payload.basedOnTailMessageID,
           payload.coveredMessageIDs.last != tail {
            return false
        }
        return true
    }
}
