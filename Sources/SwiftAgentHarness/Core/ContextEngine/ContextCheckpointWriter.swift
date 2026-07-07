import CryptoKit
import Foundation
import Logging
import SwiftAgentKit

enum ContextCheckpointWriter {
    static func persistTranscriptCompactionTreeIfNeeded(
        spec: ContextCompactionCheckpointPersistenceSpec,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard spec.config.useSessionTreeProjection,
              spec.kind == .summarized,
              let summary = spec.summaryBodyForTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              let firstKept = spec.firstKeptTailMessageID
        else { return }
        do {
            _ = try persistence.harnessSessionPersistence.recordTranscriptCompaction(
                conversationID: spec.conversationID,
                summary: summary,
                firstKeptMessageID: firstKept,
                tokensBefore: spec.promptTokensBeforeCompaction ?? 0,
                details: [
                    "strategy": .string(spec.strategyRawValue ?? ContextCompactionStrategy.default.rawValue),
                    "configFingerprint": .string(ContextCompactionCheckpointSupport.configFingerprint(spec.config)),
                ]
            )
        } catch {
            logger?.warning("[ContextCheckpointWriter] recordTranscriptCompaction failed: \(error)")
        }
    }

    struct MemoryInjectionSnapshotEntry: Codable, Sendable {
        let transformedMessageID: UUID
        let sourceMessageIDs: [UUID]
    }

    static func persistCompactionCheckpointIfNeeded(
        spec: ContextCompactionCheckpointPersistenceSpec?,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) -> Bool {
        guard let spec else { return false }
        do {
            try persistence.persistContextCompactionCheckpoint(
                conversationID: spec.conversationID,
                rawMiddleMessageIDs: spec.rawMiddleMessageIDs,
                compactedMiddleMessages: spec.compactedMiddleMessages,
                coveredRawMiddle: spec.coveredRawMiddle,
                kind: spec.kind,
                config: spec.config,
                strategyRawValue: spec.strategyRawValue,
                cachePolicyFingerprint: spec.cachePolicyFingerprint,
                expectedDerivedSequence: spec.expectedDerivedSequence
            )
            persistTranscriptCompactionTreeIfNeeded(spec: spec, persistence: persistence, logger: logger)
            return true
        } catch let conflict as JournalStreamSequenceConflict where conflict.stream == .derived {
            logger?.warning(
                "[ContextCheckpointWriter] compaction checkpoint conflict (expected=\(conflict.expected), actual=\(conflict.actual)); dropping checkpoint"
            )
            return false
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistContextCompactionCheckpoint failed: \(error)")
            return false
        }
    }

    static func persistMemoryInjectionSnapshotCheckpointIfNeeded(
        spec: ContextMemoryInjectionSnapshotSpec?,
        events: [CachedConversationEvent],
        frontierEventID: Int,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard let spec else { return }
        let entryIDs = Array(Set(spec.injectedMemoryEntryIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !entryIDs.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let snapshotData = try? encoder.encode(
            MemoryStoreSnapshotJSON(memoryEntryIDs: entryIDs, memoryStoreVersion: spec.memoryStoreVersion)
        ),
        let snapshotJSON = String(data: snapshotData, encoding: .utf8) else { return }
        let phaseRaw: String = switch spec.phase {
        case .initial:
            "initial"
        case .continuation(let round):
            "agent_build_continuation:\(round)"
        }
        let fingerprintInput = "v2|\(phaseRaw)|\(spec.conversationID.uuidString)|\(spec.memoryStoreVersion)|\(entryIDs.map(\.uuidString).joined(separator: ","))"
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let latest = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
            events: events,
            frontierEventID: frontierEventID,
            expectedMemoryStoreVersion: spec.memoryStoreVersion
        ),
           latest.wire.injectionFingerprint == fingerprint,
           latest.wire.memoryStoreNamespaceKey == spec.memoryStoreNamespaceKey,
           (latest.wire.memoryEntryIDs ?? latest.wire.scopeMessageIDs) == entryIDs {
            return
        }
        let wire = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: frontierEventID,
            injectionFingerprint: fingerprint,
            snapshotJSON: snapshotJSON,
            scopeMessageIDs: entryIDs,
            memoryStoreVersion: spec.memoryStoreVersion,
            memoryStoreNamespaceKey: spec.memoryStoreNamespaceKey,
            memoryEntryIDs: entryIDs,
            createdAt: Date()
        )
        do {
            try persistence.persistMemoryInjectionSnapshotCheckpoint(conversationID: spec.conversationID, wire: wire)
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistMemoryInjectionSnapshotCheckpoint (store-backed) failed: \(error)")
        }
    }

    static func persistPreCompactionMemoryFlushCheckpointIfNeeded(
        spec: ContextPreCompactionMemoryFlushSpec?,
        events: [CachedConversationEvent],
        frontierEventID: Int,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard let spec else { return }
        let entryIDs = Array(Set(spec.flushedMemoryEntryIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !entryIDs.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let snapshotData = try? encoder.encode(
            PreCompactionMemoryFlushSnapshotJSON(memoryEntryIDs: entryIDs, memoryStoreVersion: spec.memoryStoreVersion)
        ),
        let snapshotJSON = String(data: snapshotData, encoding: .utf8) else { return }
        let phaseRaw: String = switch spec.phase {
        case .initial:
            "initial"
        case .continuation(let round):
            "agent_build_continuation:\(round)"
        }
        let fingerprintInput = "flush-v1|\(phaseRaw)|\(spec.conversationID.uuidString)|\(spec.memoryStoreVersion)|\(entryIDs.map(\.uuidString).joined(separator: ","))"
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let latest = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
            events: events,
            frontierEventID: frontierEventID,
            expectedMemoryStoreVersion: spec.memoryStoreVersion
        ),
           latest.wire.injectionFingerprint == fingerprint,
           latest.wire.memoryStoreNamespaceKey == spec.memoryStoreNamespaceKey,
           (latest.wire.memoryEntryIDs ?? latest.wire.scopeMessageIDs) == entryIDs {
            return
        }
        let wire = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: frontierEventID,
            injectionFingerprint: fingerprint,
            snapshotJSON: snapshotJSON,
            scopeMessageIDs: entryIDs,
            memoryStoreVersion: spec.memoryStoreVersion,
            memoryStoreNamespaceKey: spec.memoryStoreNamespaceKey,
            memoryEntryIDs: entryIDs,
            createdAt: Date()
        )
        do {
            try persistence.persistMemoryInjectionSnapshotCheckpoint(conversationID: spec.conversationID, wire: wire)
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistPreCompactionMemoryFlushCheckpoint failed: \(error)")
        }
    }

    static func persistMemoryInjectionSnapshotCheckpointIfNeeded(
        conversationID: UUID,
        phase: ContextTransformInvocationPhase,
        output: ContextTransformOutput,
        events: [CachedConversationEvent],
        frontierEventID: Int,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard let provenance = output.messageProvenance, !provenance.isEmpty else { return }
        let entries = provenance
            .filter { $0.origin == .synthesized && !$0.sourceMessageIDs.isEmpty }
            .map { p in
                MemoryInjectionSnapshotEntry(
                    transformedMessageID: p.transformedMessageID,
                    sourceMessageIDs: p.sourceMessageIDs
                )
            }
        guard !entries.isEmpty else { return }

        let scopeIDs = Array(Set(entries.flatMap(\.sourceMessageIDs))).sorted { $0.uuidString < $1.uuidString }
        guard !scopeIDs.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let snapshotData = try? encoder.encode(entries),
              let snapshotJSON = String(data: snapshotData, encoding: .utf8) else {
            return
        }
        let phaseRaw: String = switch phase {
        case .initial:
            "initial"
        case .continuation(let round):
            "agent_build_continuation:\(round)"
        }
        let fingerprintInput = "v1|\(phaseRaw)|\(conversationID.uuidString)|\(snapshotJSON)"
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        if let latest = SuiteCheckpointSupport.latestValidMemoryInjectionSnapshot(
            events: events,
            frontierEventID: frontierEventID
        ),
           latest.wire.injectionFingerprint == fingerprint,
           latest.wire.scopeMessageIDs == scopeIDs {
            return
        }

        let wire = MemoryInjectionSnapshotCheckpointWire(
            schemaVersion: MemoryInjectionSnapshotCheckpointWire.currentSchemaVersion,
            basedOnEventID: frontierEventID,
            injectionFingerprint: fingerprint,
            snapshotJSON: snapshotJSON,
            scopeMessageIDs: scopeIDs,
            createdAt: Date()
        )
        do {
            try persistence.persistMemoryInjectionSnapshotCheckpoint(conversationID: conversationID, wire: wire)
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistMemoryInjectionSnapshotCheckpoint failed: \(error)")
        }
    }

    static func persistToolResultTrimCheckpointIfNeeded(
        conversationID: UUID,
        coveredMessageIDs: [UUID],
        trimmedToolCallIDs: [String],
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        let uniqueCovered = Array(Set(coveredMessageIDs)).sorted { $0.uuidString < $1.uuidString }
        let uniqueTrimmedToolCalls = Array(Set(trimmedToolCallIDs)).sorted()
        guard !uniqueCovered.isEmpty, !uniqueTrimmedToolCalls.isEmpty else { return }
        let wire = ToolResultTrimCheckpointWire(
            schemaVersion: ToolResultTrimCheckpointWire.currentSchemaVersion,
            basedOnEventID: persistence.conversationManager.latestConversationEventID(conversationID: conversationID),
            coveredMessageIDs: uniqueCovered,
            trimmedToolCallIds: uniqueTrimmedToolCalls,
            configFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            createdAt: Date()
        )
        do {
            try persistence.persistToolResultTrimCheckpoint(conversationID: conversationID, wire: wire)
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistToolResultTrimCheckpoint failed: \(error)")
        }
    }

    static func persistSystemPromptAssemblyCheckpointIfNeeded(
        conversationID: UUID,
        fingerprint: String,
        persistence: ConversationPersistenceStack
    ) throws {
        let (events, frontier) = persistence.conversationManager.loadConversationEventsWithFrontier(
            conversationID: conversationID
        )
        let prior = HarnessCheckpointContextHooks.latestSystemPromptAssemblyFingerprint(
            events: events,
            frontierEventID: frontier
        )
        if prior == fingerprint { return }
        let derivedTail = persistence.derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        let wire = SystemPromptAssemblyCheckpointWire(
            schemaVersion: SystemPromptAssemblyCheckpointWire.currentSchemaVersion,
            basedOnEventID: frontier,
            assemblyFingerprint: fingerprint,
            createdAt: Date()
        )
        try persistence.persistSystemPromptAssemblyCheckpoint(
            conversationID: conversationID,
            wire: wire,
            expectedDerivedSequence: derivedTail
        )
    }

    static func persistSystemPromptAssemblyCheckpointIfNeeded(
        spec: ContextSystemPromptAssemblyCheckpointPersistenceSpec?,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard let spec else { return }
        do {
            try persistSystemPromptAssemblyCheckpointIfNeeded(
                conversationID: spec.conversationID,
                fingerprint: spec.fingerprint,
                persistence: persistence
            )
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistSystemPromptAssemblyCheckpoint failed: \(error)")
        }
    }

    static func persistAttachmentProjectionCheckpointIfNeeded(
        spec: ContextAttachmentProjectionCheckpointPersistenceSpec?,
        events: [CachedConversationEvent],
        frontierEventID: Int,
        persistence: ConversationPersistenceStack,
        logger: Logger?
    ) {
        guard let spec, !spec.decisions.isEmpty else { return }
        if let latest = SuiteCheckpointSupport.latestValidAttachmentProjection(
            events: events,
            frontierEventID: frontierEventID,
            expectedProjectionFingerprint: spec.projectionFingerprint
        ),
           latest.wire.projectionFingerprint == spec.projectionFingerprint,
           latest.wire.decisions == spec.decisions {
            return
        }
        let wire = AttachmentProjectionCheckpointWire(
            schemaVersion: AttachmentProjectionCheckpointWire.currentSchemaVersion,
            basedOnEventID: frontierEventID,
            projectionFingerprint: spec.projectionFingerprint,
            decisions: spec.decisions,
            createdAt: Date()
        )
        do {
            try persistence.persistAttachmentProjectionCheckpoint(
                conversationID: spec.conversationID,
                wire: wire
            )
        } catch {
            logger?.warning("[ContextCheckpointWriter] persistAttachmentProjectionCheckpoint failed: \(error)")
        }
    }
}

