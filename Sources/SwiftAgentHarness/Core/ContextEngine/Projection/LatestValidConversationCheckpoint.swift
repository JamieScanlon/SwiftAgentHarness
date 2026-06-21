import Foundation
import SwiftAgentKit

/// Harness checkpoint discriminant (wire `kind` string = raw value).
enum ConversationHarnessCheckpointKind: String, Sendable, CaseIterable {
    case contextCompaction = "context_compaction"
    case memoryInjectionSnapshot = "memory_injection_snapshot"
    case toolResultTrim = "tool_result_trim"
    case systemPromptAssembly = "system_prompt_assembly"
    case attachmentProjection = "attachment_projection"
}

/// Validity-selected checkpoint for one harness kind.
enum LatestCheckpointSelection: Sendable, Equatable {
    case contextCompaction(payload: ContextCompactionCheckpointPayload, eventID: Int)
    case memoryInjectionSnapshot(wire: MemoryInjectionSnapshotCheckpointWire, eventID: Int)
    case toolResultTrim(wire: ToolResultTrimCheckpointWire, eventID: Int)
    case systemPromptAssembly(wire: SystemPromptAssemblyCheckpointWire, eventID: Int)
    case attachmentProjection(wire: AttachmentProjectionCheckpointWire, eventID: Int)
}

extension LatestCheckpointSelection {
    func toResponse() -> LatestCheckpointResponse {
        switch self {
        case .contextCompaction(let payload, let eventID):
            LatestCheckpointResponse(
                kind: HarnessCheckpointWireKind.contextCompaction.rawValue,
                eventID: eventID,
                checkpoint: .contextCompaction(payload.toWireDTO())
            )
        case .memoryInjectionSnapshot(let wire, let eventID):
            LatestCheckpointResponse(
                kind: HarnessCheckpointWireKind.memoryInjectionSnapshot.rawValue,
                eventID: eventID,
                checkpoint: .memoryInjectionSnapshot(wire)
            )
        case .toolResultTrim(let wire, let eventID):
            LatestCheckpointResponse(
                kind: HarnessCheckpointWireKind.toolResultTrim.rawValue,
                eventID: eventID,
                checkpoint: .toolResultTrim(wire)
            )
        case .systemPromptAssembly(let wire, let eventID):
            LatestCheckpointResponse(
                kind: HarnessCheckpointWireKind.systemPromptAssembly.rawValue,
                eventID: eventID,
                checkpoint: .systemPromptAssembly(wire)
            )
        case .attachmentProjection(let wire, let eventID):
            LatestCheckpointResponse(
                kind: HarnessCheckpointWireKind.attachmentProjection.rawValue,
                eventID: eventID,
                checkpoint: .attachmentProjection(wire)
            )
        }
    }
}

/// Dispatch table for validity-selected checkpoints.
enum LatestValidConversationCheckpoint {
    /// Selects the latest valid persisted checkpoint for `kind` (see `Documentation/PROJECTION.md`).
    static func latestCheckpointSelection(
        kind: ConversationHarnessCheckpointKind,
        events: [CachedConversationEvent],
        rawMiddle: [Message],
        compactionConfig: ContextCompactionConfiguration,
        toolTrimConfigFingerprint: String,
        rawMessages: [Message]? = nil,
        expectedCompactionStrategyRawValue: String? = nil,
        expectedMemoryStoreVersion: Int? = nil,
        expectedSystemPromptAssemblyFingerprint: String? = nil,
        expectedAttachmentProjectionFingerprint: String? = nil,
        frontierEventID: Int? = nil
    ) -> LatestCheckpointSelection? {
        let rawMessageIDs = rawMessages?.map(\.id)
        switch kind {
        case .contextCompaction:
            guard let pair = ContextCompactionCheckpointSupport.latestValidCheckpoint(
                events: events,
                rawMiddle: rawMiddle,
                config: compactionConfig,
                expectedStrategyRawValue: expectedCompactionStrategyRawValue,
                frontierEventID: frontierEventID
            ) else { return nil }
            return .contextCompaction(payload: pair.payload, eventID: pair.eventID)
        case .memoryInjectionSnapshot:
            guard let pair = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
                events: events,
                frontierEventID: frontierEventID,
                rawMessageIDs: rawMessageIDs,
                expectedMemoryStoreVersion: expectedMemoryStoreVersion
            ) else { return nil }
            return .memoryInjectionSnapshot(wire: pair.wire, eventID: pair.eventID)
        case .toolResultTrim:
            guard let pair = SuiteCheckpointSupport.latestValidToolResultTrim(
                events: events,
                frontierEventID: frontierEventID,
                configFingerprint: toolTrimConfigFingerprint,
                rawMessageIDs: rawMessageIDs
            ) else { return nil }
            return .toolResultTrim(wire: pair.wire, eventID: pair.eventID)
        case .systemPromptAssembly:
            guard let pair = SuiteCheckpointSupport.latestValidSystemPromptAssembly(
                events: events,
                frontierEventID: frontierEventID,
                expectedAssemblyFingerprint: expectedSystemPromptAssemblyFingerprint
            ) else { return nil }
            return .systemPromptAssembly(wire: pair.wire, eventID: pair.eventID)
        case .attachmentProjection:
            guard let pair = SuiteCheckpointSupport.latestValidAttachmentProjection(
                events: events,
                frontierEventID: frontierEventID,
                expectedProjectionFingerprint: expectedAttachmentProjectionFingerprint
            ) else { return nil }
            return .attachmentProjection(wire: pair.wire, eventID: pair.eventID)
        }
    }

    /// Canonical latest-valid selector used by manager/projection call-sites.
    static func latestValid(
        kind: ConversationHarnessCheckpointKind,
        events: [CachedConversationEvent],
        rawMiddle: [Message],
        compactionConfig: ContextCompactionConfiguration,
        toolTrimConfigFingerprint: String,
        rawMessages: [Message]? = nil,
        expectedCompactionStrategyRawValue: String? = nil,
        expectedMemoryStoreVersion: Int? = nil,
        expectedSystemPromptAssemblyFingerprint: String? = nil,
        expectedAttachmentProjectionFingerprint: String? = nil,
        frontierEventID: Int? = nil
    ) -> LatestCheckpointSelection? {
        latestCheckpointSelection(
            kind: kind,
            events: events,
            rawMiddle: rawMiddle,
            compactionConfig: compactionConfig,
            toolTrimConfigFingerprint: toolTrimConfigFingerprint,
            rawMessages: rawMessages,
            expectedCompactionStrategyRawValue: expectedCompactionStrategyRawValue,
            expectedMemoryStoreVersion: expectedMemoryStoreVersion,
            expectedSystemPromptAssemblyFingerprint: expectedSystemPromptAssemblyFingerprint,
            expectedAttachmentProjectionFingerprint: expectedAttachmentProjectionFingerprint,
            frontierEventID: frontierEventID
        )
    }

    /// Compatibility helper for compaction-only callers.
    static func latestValidCompaction(
        events: [CachedConversationEvent],
        rawMiddle: [Message],
        config: ContextCompactionConfiguration,
        expectedCompactionStrategyRawValue: String? = nil,
        frontierEventID: Int? = nil
    ) -> (payload: ContextCompactionCheckpointPayload, eventID: Int)? {
        guard case let .contextCompaction(payload, eventID)? = latestValid(
            kind: .contextCompaction,
            events: events,
            rawMiddle: rawMiddle,
            compactionConfig: config,
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: rawMiddle,
            expectedCompactionStrategyRawValue: expectedCompactionStrategyRawValue,
            frontierEventID: frontierEventID
        ) else {
            return nil
        }
        return (payload, eventID)
    }
}
