import Foundation
import SwiftAgentKit

/// Validity selection for harness checkpoints other than context compaction (shared invalidation floor semantics).
enum SuiteCheckpointSupport {
    static func latestValidMemoryInjectionSnapshot(
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil,
        rawMessageIDs: [UUID]? = nil,
        expectedMemoryStoreVersion: Int? = nil,
        expectedSelectorConfigFingerprint: String? = nil
    ) -> (wire: MemoryInjectionSnapshotCheckpointWire, eventID: Int)? {
        latestValidWireCheckpoint(
            events: events,
            persistedKind: ConversationEventKind.memoryInjectionSnapshotCheckpoint.rawValue,
            frontierEventID: frontierEventID,
            decode: { ConversationEventCodec.decode(MemoryInjectionSnapshotCheckpointWire.self, from: $0) },
            basedOnEventID: { $0.basedOnEventID },
            isValid: { wire, _ in
                guard wire.schemaVersion >= 1,
                      wire.schemaVersion <= MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
                      !wire.injectionFingerprint.isEmpty,
                      !wire.snapshotJSON.isEmpty,
                      !wire.scopeMessageIDs.isEmpty
                else { return false }
                if let expectedMemoryStoreVersion,
                   wire.memoryStoreVersion != expectedMemoryStoreVersion {
                    return false
                }
                if let expectedSelectorConfigFingerprint,
                   wire.selectorConfigFingerprint != expectedSelectorConfigFingerprint {
                    return false
                }
                guard let rawMessageIDs else { return true }
                if let prefix = MemoryInjectionSnapshotProjectionPolicy.resolvedSelectionContextPrefix(from: wire) {
                    return MemoryInjectionSnapshotProjectionPolicy.selectionContextMatches(
                        storedContext: prefix,
                        currentRawMessageIDs: rawMessageIDs
                    )
                }
                let rawMessageIDSet = Set(rawMessageIDs)
                return wire.scopeMessageIDs.allSatisfy { rawMessageIDSet.contains($0) }
            }
        )
    }

    static func latestValidToolResultTrim(
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil,
        configFingerprint: String,
        rawMessageIDs: [UUID]? = nil
    ) -> (wire: ToolResultTrimCheckpointWire, eventID: Int)? {
        let rawMessageIDSet = rawMessageIDs.map(Set.init)
        return latestValidWireCheckpoint(
            events: events,
            persistedKind: ConversationEventKind.toolResultTrimCheckpoint.rawValue,
            frontierEventID: frontierEventID,
            decode: { ConversationEventCodec.decode(ToolResultTrimCheckpointWire.self, from: $0) },
            basedOnEventID: { $0.basedOnEventID },
            isValid: { wire, _ in
                wire.schemaVersion == ToolResultTrimCheckpointWire.currentSchemaVersion
                    && wire.configFingerprint == configFingerprint
                    && !wire.coveredMessageIDs.isEmpty
                    && !wire.trimmedToolCallIds.isEmpty
                    && wire.coveredMessageIDs.allSatisfy { id in
                        rawMessageIDSet?.contains(id) ?? true
                    }
            }
        )
    }

    static func latestValidSystemPromptAssembly(
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil,
        expectedAssemblyFingerprint: String? = nil
    ) -> (wire: SystemPromptAssemblyCheckpointWire, eventID: Int)? {
        latestValidWireCheckpoint(
            events: events,
            persistedKind: ConversationEventKind.systemPromptAssemblyCheckpoint.rawValue,
            frontierEventID: frontierEventID,
            decode: { ConversationEventCodec.decode(SystemPromptAssemblyCheckpointWire.self, from: $0) },
            basedOnEventID: { $0.basedOnEventID },
            isValid: { wire, _ in
                guard !wire.assemblyFingerprint.isEmpty else { return false }
                if expectedAssemblyFingerprint != nil, wire.assemblyFingerprint != expectedAssemblyFingerprint {
                    return false
                }
                switch wire.schemaVersion {
                case 1, 2:
                    return true
                case SystemPromptAssemblyCheckpointWire.currentSchemaVersion:
                    guard let replayDigest = wire.replaySpecDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !replayDigest.isEmpty else {
                        return false
                    }
                    if let assembled = wire.assembledPrompt {
                        guard let digest = wire.assembledPromptDigest,
                              digest == SystemPromptDispatchCodec.sha256Digest(of: assembled) else {
                            return false
                        }
                    }
                    return true
                default:
                    return false
                }
            }
        )
    }

    static func latestValidAttachmentProjection(
        events: [CachedConversationEvent],
        frontierEventID: Int? = nil,
        expectedProjectionFingerprint: String? = nil
    ) -> (wire: AttachmentProjectionCheckpointWire, eventID: Int)? {
        latestValidWireCheckpoint(
            events: events,
            persistedKind: ConversationEventKind.attachmentProjectionCheckpoint.rawValue,
            frontierEventID: frontierEventID,
            decode: { ConversationEventCodec.decode(AttachmentProjectionCheckpointWire.self, from: $0) },
            basedOnEventID: { $0.basedOnEventID },
            isValid: { wire, _ in
                (wire.schemaVersion == 1 || wire.schemaVersion == AttachmentProjectionCheckpointWire.currentSchemaVersion)
                    && !wire.projectionFingerprint.isEmpty
                    && !wire.decisions.isEmpty
                    && (expectedProjectionFingerprint == nil || wire.projectionFingerprint == expectedProjectionFingerprint)
            }
        )
    }

    private static func latestValidWireCheckpoint<Wire>(
        events: [CachedConversationEvent],
        persistedKind: String,
        frontierEventID: Int?,
        decode: (String) -> Wire?,
        basedOnEventID: (Wire) -> Int,
        isValid: (Wire, CachedConversationEvent) -> Bool
    ) -> (wire: Wire, eventID: Int)? {
        let resolvedFrontier = frontierEventID ?? (events.map(\.eventID).max() ?? 0)
        let floor = DerivedArtifactContractMatrix.invalidationFloor(
            events: events,
            forPersistedKind: persistedKind
        )
        for event in events
            .filter({ $0.kind == persistedKind })
            .sorted(by: { $0.eventID > $1.eventID })
        {
            guard event.eventID > floor else { continue }
            guard let wire = decode(event.payloadJSON) else { continue }
            guard isValid(wire, event) else { continue }
            guard basedOnEventID(wire) <= resolvedFrontier else { continue }
            return (wire, event.eventID)
        }
        return nil
    }
}
