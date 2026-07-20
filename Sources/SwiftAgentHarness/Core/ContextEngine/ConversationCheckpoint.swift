import Foundation

/// Harness-aligned umbrella for persisted **derived** artifacts (checkpoints).
enum ConversationCheckpoint: Sendable, Equatable {
    case compaction(ContextCompactionCheckpointPayload)
    case memoryInjectionSnapshot(MemoryInjectionSnapshotCheckpointWire)
    case toolResultTrim(ToolResultTrimCheckpointWire)
    case systemPromptAssembly(SystemPromptAssemblyCheckpointWire)
    case attachmentProjection(AttachmentProjectionCheckpointWire)
    case attachmentDigest(AttachmentDigestCheckpointWire)

    /// Maps persisted conversation events to checkpoint values (unknown kinds skipped).
    static func load(from events: [CachedConversationEvent]) -> [ConversationCheckpoint] {
        events.compactMap { event -> ConversationCheckpoint? in
            switch event.kind {
            case ConversationEventKind.contextCompactionCheckpoint.rawValue:
                guard let payload = ConversationEventCodec.decode(
                    ContextCompactionCheckpointPayload.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .compaction(payload)
            case ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue:
                guard let w = ConversationEventCodec.decode(
                    MemoryInjectionSnapshotCheckpointWire.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .memoryInjectionSnapshot(w)
            case ConversationEventKind.toolResultTrimCheckpoint.rawValue:
                guard let w = ConversationEventCodec.decode(
                    ToolResultTrimCheckpointWire.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .toolResultTrim(w)
            case ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue:
                guard let w = ConversationEventCodec.decode(
                    SystemPromptAssemblyCheckpointWire.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .systemPromptAssembly(w)
            case ConversationEventKind.attachmentProjectionCheckpoint.rawValue:
                guard let w = ConversationEventCodec.decode(
                    AttachmentProjectionCheckpointWire.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .attachmentProjection(w)
            case ConversationEventKind.attachmentDigestCheckpoint.rawValue:
                guard let w = ConversationEventCodec.decode(
                    AttachmentDigestCheckpointWire.self,
                    from: event.payloadJSON
                ) else { return nil }
                return .attachmentDigest(w)
            default:
                return nil
            }
        }
    }
}
