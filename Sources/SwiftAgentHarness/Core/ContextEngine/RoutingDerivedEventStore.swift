//
//  Derived journal appends on harness transcript (`derived_journal`).
//

import Foundation
import SwiftAgentKit

final class RoutingDerivedEventStore: DerivedEventStore, Sendable {
    private let harness: any HarnessSessionPersistence

    init(harness: any HarnessSessionPersistence) {
        self.harness = harness
    }

    func latestDerivedStreamSequence(conversationID: UUID) -> Int {
        TranscriptConversationJournalWriter.latestDerivedStreamSequence(
            harness: harness,
            conversationID: conversationID
        )
    }

    private func journalEvents(conversationID: UUID) -> [CachedConversationEvent] {
        TranscriptConversationJournalWriter.loadEventsWithFrontier(
            harness: harness,
            conversationID: conversationID
        ).0
    }

    private func latestGlobalEventID(conversationID: UUID) -> Int {
        TranscriptConversationJournalWriter.latestGlobalEventID(
            harness: harness,
            conversationID: conversationID
        )
    }

    private func appendDerived(
        conversationID: UUID,
        kind: ConversationEventKind,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        try TranscriptConversationJournalWriter.appendDerivedJournalEntry(
            harness: harness,
            conversationID: conversationID,
            kind: kind,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendContextCompactionCheckpoint(
        conversationID: UUID,
        rawMiddleMessageIDs: [UUID],
        compactedMiddleMessages: [Message],
        coveredRawMiddle: [Message],
        kind: ContextCompactionCheckpointKind,
        config: ContextCompactionConfiguration,
        strategyRawValue: String?,
        cachePolicyFingerprint: String?,
        expectedDerivedSequence: Int?
    ) throws {
        guard !rawMiddleMessageIDs.isEmpty else { return }
        let syntheticMessages = ContextCompactionCheckpointSupport.summarizedSyntheticDTOsForPersistence(
            summaryMessages: compactedMiddleMessages,
            coveredRawMiddle: coveredRawMiddle,
            kind: kind
        )
        let configFingerprint = ContextCompactionCheckpointSupport.configFingerprint(config)
        if ContextCompactionCheckpointSupport.matchingIdempotentContextCompactionCheckpointEventID(
            events: journalEvents(conversationID: conversationID),
            coveredMessageIDs: rawMiddleMessageIDs,
            syntheticMessages: syntheticMessages,
            kind: kind,
            configFingerprint: configFingerprint,
            strategyRawValue: strategyRawValue,
            cachePolicyFingerprint: cachePolicyFingerprint
        ) != nil {
            return
        }
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let payload = ContextCompactionCheckpointPayload(
            schemaVersion: ContextCompactionCheckpointPayload.currentSchemaVersion,
            kind: kind,
            coveredMessageIDs: rawMiddleMessageIDs,
            syntheticMessages: syntheticMessages,
            configFingerprint: configFingerprint,
            basedOnEventID: basedOnGlobal,
            basedOnTailMessageID: rawMiddleMessageIDs.last,
            strategyRawValue: strategyRawValue,
            cachePolicyFingerprint: cachePolicyFingerprint,
            createdAt: Date()
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .contextCompactionCheckpoint,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: payload.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendTurnSummaryEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        try appendDerived(
            conversationID: conversationID,
            kind: .turnSummaryEvent,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendTurnFinalizedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        try appendDerived(
            conversationID: conversationID,
            kind: .turnFinalized,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendCompactionAppliedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        try appendDerived(
            conversationID: conversationID,
            kind: .compactionApplied,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendCheckpointInvalidation(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let payload = CheckpointInvalidatedEventPayload(kinds: kinds)
        try appendDerived(
            conversationID: conversationID,
            kind: .checkpointInvalidated,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: Date(),
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendMemoryInjectionSnapshotCheckpoint(
        conversationID: UUID,
        wire: MemoryInjectionSnapshotCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let persist = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: wire.schemaVersion,
            basedOnEventID: basedOnGlobal,
            injectionFingerprint: wire.injectionFingerprint,
            snapshotJSON: wire.snapshotJSON,
            scopeMessageIDs: wire.scopeMessageIDs,
            memoryStoreVersion: wire.memoryStoreVersion,
            memoryStoreNamespaceKey: wire.memoryStoreNamespaceKey,
            memoryEntryIDs: wire.memoryEntryIDs,
            createdAt: wire.createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .memoryInjectionSnapshotCheckpoint,
            payloadJSON: ConversationEventCodec.encode(persist),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: persist.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendToolResultTrimCheckpoint(
        conversationID: UUID,
        wire: ToolResultTrimCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let persist = ToolResultTrimCheckpointWire(
            schemaVersion: wire.schemaVersion,
            basedOnEventID: basedOnGlobal,
            coveredMessageIDs: wire.coveredMessageIDs,
            trimmedToolCallIds: wire.trimmedToolCallIds,
            configFingerprint: wire.configFingerprint,
            createdAt: wire.createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .toolResultTrimCheckpoint,
            payloadJSON: ConversationEventCodec.encode(persist),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: persist.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendSystemPromptAssemblyCheckpoint(
        conversationID: UUID,
        wire: SystemPromptAssemblyCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let persist = SystemPromptAssemblyCheckpointWire(
            schemaVersion: wire.schemaVersion,
            basedOnEventID: basedOnGlobal,
            assemblyFingerprint: wire.assemblyFingerprint,
            assembledPromptDigest: wire.assembledPromptDigest,
            replaySpecDigest: wire.replaySpecDigest,
            assembledPrompt: wire.assembledPrompt,
            sectionProvenanceJSON: wire.sectionProvenanceJSON,
            createdAt: wire.createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .systemPromptAssemblyCheckpoint,
            payloadJSON: ConversationEventCodec.encode(persist),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: persist.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendAttachmentProjectionCheckpoint(
        conversationID: UUID,
        wire: AttachmentProjectionCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let persist = AttachmentProjectionCheckpointWire(
            schemaVersion: wire.schemaVersion,
            basedOnEventID: basedOnGlobal,
            projectionFingerprint: wire.projectionFingerprint,
            decisions: wire.decisions,
            targetDecisions: wire.targetDecisions,
            materializedBlocks: wire.materializedBlocks,
            accessWatermarkTurnIndex: wire.accessWatermarkTurnIndex,
            createdAt: wire.createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .attachmentProjectionCheckpoint,
            payloadJSON: ConversationEventCodec.encode(persist),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: persist.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendAttachmentDigestCheckpoint(
        conversationID: UUID,
        wire: AttachmentDigestCheckpointWire,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let persist = AttachmentDigestCheckpointWire(
            schemaVersion: wire.schemaVersion,
            basedOnEventID: basedOnGlobal,
            attachmentID: wire.attachmentID,
            contentHash: wire.contentHash,
            configFingerprint: wire.configFingerprint,
            digestBody: wire.digestBody,
            createdAt: wire.createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .attachmentDigestCheckpoint,
            payloadJSON: ConversationEventCodec.encode(persist),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: persist.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendRunLifecycleEvent(
        conversationID: UUID,
        runID: UUID,
        status: ConversationRunWireStatus,
        terminalReason: ConversationRunTerminalReason?,
        markerKind: String?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        let payload = RunLifecycleEventPayload(
            runID: runID,
            status: status,
            terminalReason: terminalReason,
            markerKind: markerKind,
            createdAt: createdAt
        )
        try appendDerived(
            conversationID: conversationID,
            kind: .runLifecycleEvent,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        try appendDerived(
            conversationID: conversationID,
            kind: .toolAuditLifecycleEvent,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: payload.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendToolUsageSummaryEvent(
        conversationID: UUID,
        payload: ToolUsageSummaryEventPayload,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        try appendDerived(
            conversationID: conversationID,
            kind: .toolUsageSummaryEvent,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: payload.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func appendCompletionAnnounceEvent(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int?
    ) throws {
        let basedOnGlobal = latestGlobalEventID(conversationID: conversationID)
        try appendDerived(
            conversationID: conversationID,
            kind: .completionAnnounceEvent,
            payloadJSON: ConversationEventCodec.encode(payload),
            basedOnEventID: basedOnGlobal,
            coversStartEventID: nil,
            coversEndEventID: nil,
            createdAt: payload.createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }
}
