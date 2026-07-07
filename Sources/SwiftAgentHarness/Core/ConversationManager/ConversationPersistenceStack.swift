//
//  Composition-root owner for conversation persistence (harness catalog + transcript journal),
//  derived compaction checkpoints, and harness session install. Conversation Manager is the primary client;
//  Agent Runtime (`HarnessRuntimeSession`) persists via this stack.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftData

/// Owns `ModelContainer`, ``ConversationManager``, ``ConversationEventLogService``, and
/// ``DerivedEventStore``. Constructed once inside ``ConversationPersistenceDomain`` (composition root / tests).
/// Actor-isolated via ``ConversationPersistenceDomain``; not passed across isolation boundaries.
final class ConversationPersistenceStack {
    let modelContainer: ModelContainer
    let conversationManager: ConversationManager
    let eventLog: ConversationEventLogService
    let derivedEventStore: any DerivedEventStore

    var harnessSessionPersistence: any HarnessSessionPersistence {
        conversationManager.harnessSessionPersistence
    }

    /// Harness template ``SessionBackend`` for the installed backend (alias of ``HarnessSessionPersistence``).
    var sessionBackend: any SessionBackend { harnessSessionPersistence }

    init(
        modelContainer: ModelContainer,
        conversationManager: ConversationManager,
        eventLog: ConversationEventLogService,
        derivedEventStore: any DerivedEventStore
    ) {
        self.modelContainer = modelContainer
        self.conversationManager = conversationManager
        self.eventLog = eventLog
        self.derivedEventStore = derivedEventStore
        conversationManager.attachPersistenceCoordinator(self)
    }

    /// Production path: default store URL, harness install, transcript-backed event log and derived store.
    static func makeProduction(
        logger: Logger?,
        dataStoreURL: URL?,
        allowsSwiftDataSave: Bool
    ) -> ConversationPersistenceStack {
        guard SessionPersistenceConfiguration.sessionStoreRoot != nil else {
            fatalError("SAH_SESSION_STORE_ROOT is required. LocalHarnessSessionPersistence is the only supported runtime SessionBackend.")
        }
        let modelContainer = HarnessPersistenceBootstrap.makeModelContainer(
            dataStoreURL: dataStoreURL,
            allowsSwiftDataSave: allowsSwiftDataSave,
            logger: logger
        )
        let conversationManager = ConversationManager(container: modelContainer, logger: logger)
        do {
            try SessionPersistenceInstall.applyToConversationManagerIfConfigured(conversationManager, logger: logger)
        } catch {
            fatalError("SessionPersistenceInstall failed with LocalHarnessSessionPersistence required: \(error)")
        }
        do {
            try conversationManager.resetConversationsFromCatalog(availableModels: [])
        } catch {
            logger?.error("Failed to load catalog conversations after v2 session install: \(error)")
        }
        let harness = conversationManager.harnessSessionPersistence
        let eventLog = ConversationEventLogService(harness: harness)
        let derivedEventStore = RoutingDerivedEventStore(harness: harness)
        return ConversationPersistenceStack(
            modelContainer: modelContainer,
            conversationManager: conversationManager,
            eventLog: eventLog,
            derivedEventStore: derivedEventStore
        )
    }

    /// In-memory or custom container (tests).
    static func makeForTesting(
        container: ModelContainer,
        logger: Logger?,
        derivedEventStore: (any DerivedEventStore)? = nil,
        harnessSessionPersistenceOverride: (any HarnessSessionPersistence)? = nil
    ) -> ConversationPersistenceStack {
        let conversationManager = ConversationManager(container: container, logger: logger)
        if SessionPersistenceConfiguration.sessionStoreRoot != nil {
            try? conversationManager.resetConversationsFromCatalog(availableModels: [])
        }
        do {
            try SessionPersistenceInstall.applyToConversationManagerIfConfigured(conversationManager, logger: logger)
        } catch {
            logger?.error(
                "SessionPersistenceInstall failed — continuing without on-disk v2 harness mirror (SAH_SESSION_STORE_ROOT unset or install error). Error: \(error)"
            )
        }
        if let harnessSessionPersistenceOverride {
            conversationManager.setHarnessSessionPersistenceOverride(harnessSessionPersistenceOverride)
        }
        let harness = conversationManager.harnessSessionPersistence
        let eventLog = ConversationEventLogService(harness: harness)
        let derived = derivedEventStore ?? RoutingDerivedEventStore(harness: harness)
        return ConversationPersistenceStack(
            modelContainer: container,
            conversationManager: conversationManager,
            eventLog: eventLog,
            derivedEventStore: derived
        )
    }

    // MARK: - Spec-shaped persistence facades (harness transcript journal)

    /// Append-only raw journal entries (`message_appended`). Pass `expectedLastMessageId` for optimistic concurrency; `nil` uses current tail.
    func appendMessageJournalEntries(
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID? = nil
    ) throws {
        try TranscriptConversationJournalWriter.appendMessageAppendedEvents(
            harness: conversationManager.harnessSessionPersistence,
            conversationID: conversationID,
            messages: messages,
            expectedLastMessageId: expectedLastMessageId
        )
    }

    /// Raw-stream durability marker when interaction mode or phase changes (harness transcript journal).
    func appendInteractionModeChangedEvent(
        conversationID: UUID,
        payload: InteractionModeChangedEventPayload,
        expectedRawSequence: Int? = nil
    ) throws {
        let harness = conversationManager.harnessSessionPersistence
        let lock = try harness.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { lock.unlock() }
        let entries = (try? harness.readTranscriptEntries(conversationID: conversationID, request: .full)) ?? []
        let tail = SessionTranscriptV2JournalTails.latestRawStreamSequence(entries: entries)
        let expectedSeq = expectedRawSequence ?? tail
        if expectedSeq != tail {
            throw JournalStreamSequenceConflict(stream: .raw, expected: expectedSeq, actual: tail)
        }
        let nextGlobal = SessionTranscriptV2JournalTails.latestGlobalEventID(entries: entries) + 1
        let nextRaw = tail + 1
        let inner = ConversationEventCodec.encode(payload)
        let env = SessionTranscriptJournalEnvelope(
            eventID: nextGlobal,
            journalStreamRaw: ConversationJournalStream.raw.rawValue,
            streamSequence: nextRaw,
            kind: ConversationEventKind.interactionModeChanged.rawValue,
            basedOnEventID: nextGlobal - 1,
            coversStartEventID: nil,
            coversEndEventID: nil,
            innerPayloadJSON: inner
        )
        let json = try SessionTranscriptJournalEnvelopeCodec.encode(env)
        let parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: harness
        )
        let seq = try harness.nextTranscriptSequence(conversationID: conversationID)
        let entry = SessionTranscriptEntry(
            sequence: seq,
            entryId: .generate(),
            parentEntryId: parentEntryId,
            type: .conversationJournal,
            timestamp: Date(),
            payloadJSON: json
        )
        try harness.appendMirroredTranscriptEntry(conversationID: conversationID, entry: entry)
    }

    /// Context Engine compaction checkpoint (`record_compaction` / derived store analogue).
    func persistContextCompactionCheckpoint(
        conversationID: UUID,
        rawMiddleMessageIDs: [UUID],
        compactedMiddleMessages: [Message],
        coveredRawMiddle: [Message],
        kind: ContextCompactionCheckpointKind,
        config: ContextCompactionConfiguration,
        strategyRawValue: String? = nil,
        cachePolicyFingerprint: String? = nil,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendContextCompactionCheckpoint(
            conversationID: conversationID,
            rawMiddleMessageIDs: rawMiddleMessageIDs,
            compactedMiddleMessages: compactedMiddleMessages,
            coveredRawMiddle: coveredRawMiddle,
            kind: kind,
            config: config,
            strategyRawValue: strategyRawValue,
            cachePolicyFingerprint: cachePolicyFingerprint,
            expectedDerivedSequence: expected
        )
    }

    func appendTurnSummaryEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendTurnSummaryEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expected
        )
    }

    func appendTurnFinalizedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendTurnFinalizedEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expected
        )
    }

    /// Persist a memory-injection checkpoint snapshot (derived stream) with optimistic tail sequencing.
    func persistMemoryInjectionSnapshotCheckpoint(
        conversationID: UUID,
        wire: MemoryInjectionSnapshotCheckpointWire,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendMemoryInjectionSnapshotCheckpoint(
            conversationID: conversationID,
            wire: wire,
            expectedDerivedSequence: expected
        )
    }

    /// Persist a tool-result trim checkpoint snapshot (derived stream) with optimistic tail sequencing.
    func persistToolResultTrimCheckpoint(
        conversationID: UUID,
        wire: ToolResultTrimCheckpointWire,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendToolResultTrimCheckpoint(
            conversationID: conversationID,
            wire: wire,
            expectedDerivedSequence: expected
        )
    }

    /// Persist a system-prompt assembly fingerprint checkpoint (derived stream).
    func persistSystemPromptAssemblyCheckpoint(
        conversationID: UUID,
        wire: SystemPromptAssemblyCheckpointWire,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendSystemPromptAssemblyCheckpoint(
            conversationID: conversationID,
            wire: wire,
            expectedDerivedSequence: expected
        )
    }

    /// Persist a CE attachment projection checkpoint snapshot (derived stream).
    func persistAttachmentProjectionCheckpoint(
        conversationID: UUID,
        wire: AttachmentProjectionCheckpointWire,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendAttachmentProjectionCheckpoint(
            conversationID: conversationID,
            wire: wire,
            expectedDerivedSequence: expected
        )
    }

    /// Append a runs.md lifecycle marker on the v2 transcript (`run_cancelled`, `run_orphaned`, …).
    func persistRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        let harness = conversationManager.harnessSessionPersistence
        try harness.appendRunLifecycleTranscriptMarker(conversationID: conversationID, payload: payload)
    }

    func persistToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendToolAuditLifecycleEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expected
        )
    }

    func persistToolUsageSummaryEvent(
        conversationID: UUID,
        payload: ToolUsageSummaryEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendToolUsageSummaryEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expected
        )
    }

    func persistCompletionAnnounceEvent(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendCompletionAnnounceEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expected
        )
    }

    /// Supersedes prior harness checkpoints for the listed kinds (derived journal).
    func appendCheckpointInvalidation(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int? = nil
    ) throws {
        let expected = expectedDerivedSequence ?? derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        try derivedEventStore.appendCheckpointInvalidation(
            conversationID: conversationID,
            kinds: kinds,
            expectedDerivedSequence: expected
        )
    }

    /// Rewinds catalog ``head_entry_id`` to the anchor user message; JSONL rows are retained (harness tree revert).
    func revertConversationPreservingPrefixThroughUserMessage(
        conversationID: UUID,
        userMessageID: UUID
    ) throws -> [Message] {
        let harness = conversationManager.harnessSessionPersistence
        guard conversationManager.modelConversation(id: conversationID) != nil
            || (try? harness.catalogConversation(id: conversationID)) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        guard let head = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: harness
        ) else {
            throw ConversationServiceError.invalidRevertTarget
        }
        let lineage = try harness.readLineage(conversationID: conversationID, leafEntryId: head)
        guard let anchorIndex = lineage.firstIndex(where: { entry in
            guard entry.type == .message || entry.type == .system else { return false }
            guard let msg = try? SessionTranscriptMapping.messageForReplay(from: entry) else { return false }
            guard msg.role == .user else { return false }
            return msg.id == userMessageID
        }) else {
            throw ConversationServiceError.invalidRevertTarget
        }
        let anchorEntry = lineage[anchorIndex]
        _ = try harness.setActiveHeadEntryId(
            conversationID: conversationID,
            entryId: anchorEntry.entryId,
            expectedRevision: nil
        )
        if var conv = conversationManager.modelConversation(id: conversationID) {
            conv.updatedAt = Date()
            try? conversationManager.syncConversationCatalogStateToSessionBackend(conversation: conv)
        }
        let prefixLineage = Array(lineage[...anchorIndex])
        return prefixLineage.compactMap { entry in
            guard entry.type == .message || entry.type == .system else { return nil }
            return try? SessionTranscriptMapping.messageForReplay(from: entry)
        }
    }

    func revertConversationPreservingPrefixThroughMessage(
        conversationID: UUID,
        messageID: UUID
    ) throws -> [Message] {
        let harness = conversationManager.harnessSessionPersistence
        guard conversationManager.modelConversation(id: conversationID) != nil
            || (try? harness.catalogConversation(id: conversationID)) != nil else {
            throw ConversationServiceError.conversationNotFound
        }
        guard let head = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: harness
        ) else {
            throw ConversationServiceError.invalidRevertTarget
        }
        let lineage = try harness.readLineage(conversationID: conversationID, leafEntryId: head)
        guard let preserveIndex = lineage.firstIndex(where: { entry in
            guard entry.type == .message || entry.type == .system else { return false }
            guard let msg = try? SessionTranscriptMapping.messageForReplay(from: entry) else { return false }
            return msg.id == messageID
        }) else {
            throw ConversationServiceError.invalidRevertTarget
        }
        let preserveEntry = lineage[preserveIndex]
        _ = try harness.setActiveHeadEntryId(
            conversationID: conversationID,
            entryId: preserveEntry.entryId,
            expectedRevision: nil
        )
        if var conv = conversationManager.modelConversation(id: conversationID) {
            conv.updatedAt = Date()
            try? conversationManager.syncConversationCatalogStateToSessionBackend(conversation: conv)
        }
        let prefixLineage = Array(lineage[...preserveIndex])
        return prefixLineage.compactMap { entry in
            guard entry.type == .message || entry.type == .system else { return nil }
            return try? SessionTranscriptMapping.messageForReplay(from: entry)
        }
    }

    func revertActiveBranchRemovingAssistantMessage(
        conversationID: UUID,
        assistantMessageID: UUID
    ) throws -> [Message] {
        let harness = conversationManager.harnessSessionPersistence
        let activeMessages = try ConversationTranscriptLineage.activeMessages(
            conversationID: conversationID,
            harness: harness
        )
        guard let tail = activeMessages.last,
              tail.id == assistantMessageID,
              tail.role == .assistant else {
            throw ConversationServiceError.invalidRevertTarget
        }
        guard activeMessages.count > 1 else {
            throw ConversationServiceError.invalidRevertTarget
        }
        let preserveThroughID = activeMessages[activeMessages.count - 2].id
        return try revertConversationPreservingPrefixThroughMessage(
            conversationID: conversationID,
            messageID: preserveThroughID
        )
    }

    func applyBackgroundCompactionIfEligible(conversationID: UUID) {
        let latestEventID = eventLog.latestConversationEventID(conversationID: conversationID)
        guard latestEventID > 0 else { return }
        let harness = conversationManager.harnessSessionPersistence
        guard let latestFinalized = TranscriptConversationJournalWriter.fetchLatestTurnFinalizedEvent(
            harness: harness,
            conversationID: conversationID
        ) else {
            return
        }
        guard latestFinalized.eventID == latestEventID else {
            return
        }

        let lastCompactionUpto = TranscriptConversationJournalWriter.latestCompactionAppliedUptoEventID(
            harness: harness,
            conversationID: conversationID
        ) ?? 0
        guard latestEventID - lastCompactionUpto >= 10 else {
            return
        }

        let snapshotID = UUID()
        let payloadJSON = ConversationEventCodec.encode(
            CompactionAppliedEventPayload(
                uptoEventID: latestEventID,
                snapshotID: snapshotID,
                createdAt: Date()
            )
        )
        try? derivedEventStore.appendCompactionAppliedEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: latestEventID,
            createdAt: Date(),
            expectedDerivedSequence: derivedEventStore.latestDerivedStreamSequence(conversationID: conversationID)
        )
    }

    /// Appends one message to the harness transcript for the conversation.
    func saveMessage(
        _ message: Message,
        for conversationID: UUID,
        resourceManager: ResourceManager?,
        logger: Logger?,
        expectedPreviousTailHarnessMessageID: UUID? = nil,
        transcriptRunID: UUID? = nil
    ) throws -> Message {
        if message.role == .tool {
            if let tid = message.toolCallId, !tid.isEmpty {
                logger?.debug("[Persistence] saveMessage: tool id=\(message.id) toolCallId=\(tid) contentChars=\(message.content.count)")
            } else {
                logger?.warning("[Persistence] saveMessage: tool id=\(message.id) toolCallId=nilOrEmpty contentChars=\(message.content.count)")
            }
        }

        let catalogBacked = (try? conversationManager.sessionBackend.catalogConversation(id: conversationID)) != nil
        if SessionPersistenceConfiguration.harnessOnDiskV2Configured || catalogBacked {
            return try saveMessageTranscriptOnly(
                message,
                for: conversationID,
                resourceManager: resourceManager,
                logger: logger,
                expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
                transcriptRunID: transcriptRunID
            )
        }

        throw ConversationServiceError.conversationNotFound
    }

    private func saveMessageTranscriptOnly(
        _ message: Message,
        for conversationID: UUID,
        resourceManager: ResourceManager?,
        logger: Logger?,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) throws -> Message {
        let harness = conversationManager.harnessSessionPersistence
        let transcriptLock = try harness.acquireTranscriptWriteLock(conversationID: conversationID, allowReentrant: false)
        defer { transcriptLock.unlock() }

        let lineageMessages = try ConversationTranscriptLineage.activeMessages(
            conversationID: conversationID,
            harness: harness
        )
        let persistedTimestamp = Self.monotonicTimestampForLineageAppend(
            incoming: message.timestamp,
            role: message.role,
            activeMessages: lineageMessages
        )
        let persistedMessage = Message(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: persistedTimestamp,
            images: message.images,
            toolCalls: message.toolCalls,
            toolCallId: message.toolCallId,
            responseFormat: message.responseFormat,
            inputTrustRaw: message.inputTrustRaw
        )

        if let expectedTail = expectedPreviousTailHarnessMessageID {
            let actualTailMessageID = try ConversationTranscriptLineage.harnessTailMessageID(
                conversationID: conversationID,
                harness: harness
            )
            if actualTailMessageID != expectedTail {
                throw ConversationServiceError.transcriptTailMismatch(
                    conversationID: conversationID,
                    expectedTailMessageID: expectedTail,
                    actualTailMessageID: actualTailMessageID
                )
            }
        }

        let parentEntryId = try ConversationTranscriptLineage.resolvedHeadEntryId(
            conversationID: conversationID,
            harness: harness
        )
        let v2Sequence = try harness.nextTranscriptSequence(conversationID: conversationID)
        let resolvedTranscriptRunID: UUID? = {
            if let transcriptRunID { return transcriptRunID }
            switch message.role {
            case .user, .assistant, .tool:
                return conversationManager.modelConversation(id: conversationID)?.currentRunID
            case .system:
                return nil
            }
        }()
        let entry = try SessionTranscriptMapping.entry(
            from: persistedMessage,
            sequence: v2Sequence,
            parentEntryId: parentEntryId,
            transcriptRunID: resolvedTranscriptRunID
        )
        try harness.appendMirroredTranscriptEntry(conversationID: conversationID, entry: entry)
        conversationManager.appendPersistedMessageToRegistry(persistedMessage, conversationID: conversationID)
        return persistedMessage
    }

    private static func monotonicTimestampForLineageAppend(
        incoming: Date,
        role: MessageRole,
        activeMessages: [Message]
    ) -> Date {
        guard role != .system else { return incoming }
        guard let tail = activeMessages.last else { return incoming }
        guard incoming <= tail.timestamp else { return incoming }
        return tail.timestamp.addingTimeInterval(0.001)
    }
}
