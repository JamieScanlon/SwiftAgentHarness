//
//  Harness-shaped **read** / UI **project** façade.
//

import Foundation
import SwiftAgentKit

extension ConversationManager {
    private func journalEventWire(_ event: CachedConversationEvent) -> ConversationJournalEventWire {
        ConversationJournalEventWire(
            eventID: event.eventID,
            kind: event.kind,
            payloadJSON: event.payloadJSON,
            basedOnEventID: event.basedOnEventID,
            coversStartEventID: event.coversStartEventID,
            coversEndEventID: event.coversEndEventID,
            createdAt: event.createdAt,
            journalStream: ConversationJournalStream(rawValue: event.journalStreamRaw)
                ?? ConversationJournalStream(persistedEventKind: event.kind),
            streamSequence: event.streamSequence
        )
    }

    /// Control-plane `read(id, { includeDerived: true })` payload.
    func readConversationWithDerived(
        conversationID: UUID,
        projectedConversation: ModelConversation
    ) -> ConversationReadWithDerivedResponse? {
        guard modelConversation(id: conversationID) != nil else { return nil }
        let raw = rawMessages(conversationID: conversationID) ?? []
        let (events, _) = loadConversationEventsWithFrontier(conversationID: conversationID)
        let derived = events
            .filter {
                (ConversationJournalStream(rawValue: $0.journalStreamRaw)
                    ?? ConversationJournalStream(persistedEventKind: $0.kind)) == .derived
            }
            .map(journalEventWire(_:))
        return ConversationReadWithDerivedResponse(
            conversation: projectedConversation,
            rawEvents: raw,
            derivedEvents: derived
        )
    }

    /// Control-plane `project(id, config?)` payload.
    func projectConversation(
        conversationID: UUID,
        request: ConversationProjectRequest
    ) -> ConversationProjectResponse {
        guard let conversation = modelConversation(id: conversationID) else {
            return ConversationProjectResponse(
                projectedMessages: [],
                metadata: ConversationProjectionMetadata(
                    frontierEventID: 0,
                    rawEventCount: 0,
                    derivedEventCount: 0,
                    config: request.config
                )
            )
        }
        let base = transcriptBaseMessages(for: conversation)
        let projection = projectUIMessagesWithMetrics(
            conversationID: conversationID,
            baseMessages: base
        )
        let (events, _) = loadConversationEventsWithFrontier(conversationID: conversationID)
        let rawEventCount = events.filter {
            (ConversationJournalStream(rawValue: $0.journalStreamRaw)
                ?? ConversationJournalStream(persistedEventKind: $0.kind)) == .raw
        }.count
        let derivedEventCount = max(0, events.count - rawEventCount)
        return ConversationProjectResponse(
            projectedMessages: projection.messages,
            metadata: ConversationProjectionMetadata(
                frontierEventID: projection.frontierEventID,
                rawEventCount: rawEventCount,
                derivedEventCount: derivedEventCount,
                config: request.config
            )
        )
    }

    /// Base transcript for projection from the transcript store (active branch via ``head_entry_id`` / ``readLineage``).
    func transcriptBaseMessages(for conversation: ModelConversation) -> [Message] {
        let transcriptEntries = try? harnessSessionPersistence.readTranscriptEntries(
            conversationID: conversation.id,
            request: .full
        )
        if transcriptEntries?.isEmpty != false {
            return SessionBlobMessageHydration.hydrateBlobImages(
                in: conversation.messages,
                harness: harnessSessionPersistence
            )
        }
        guard let base = try? ConversationTranscriptLineage.activeMessages(
            conversationID: conversation.id,
            harness: harnessSessionPersistence
        ), !base.isEmpty else {
            return SessionBlobMessageHydration.hydrateBlobImages(
                in: conversation.messages,
                harness: harnessSessionPersistence
            )
        }
        return SessionBlobMessageHydration.hydrateBlobImages(in: base, harness: harnessSessionPersistence)
    }

    /// Harness **raw** transcript: messages as stored (no turn-summary overlay).
    func rawMessages(conversationID: UUID) -> [Message]? {
        guard let conversation = modelConversation(id: conversationID) else { return nil }
        return transcriptBaseMessages(for: conversation)
    }

    /// UI projection: turn summaries and related journal overlays (`ConversationEventProjector`).
    func projectedMessagesForUI(conversation: ModelConversation) -> [Message] {
        let base = transcriptBaseMessages(for: conversation)
        let (events, frontier) = loadConversationEventsWithFrontier(conversationID: conversation.id)
        return ConversationEventProjector.projectMessages(
            baseMessages: base,
            events: events,
            frontierEventID: frontier
        )
    }

    /// UI projection with metrics and store frontier (same load path as ``HarnessRuntimeSession/refreshProjectedConversationMessages``).
    func projectUIMessagesWithMetrics(
        conversationID: UUID,
        baseMessages: [Message]
    ) -> (
        messages: [Message],
        metrics: ConversationProjection.ProjectionMetrics,
        frontierEventID: Int
    ) {
        let (events, frontier) = loadConversationEventsWithFrontier(conversationID: conversationID)
        return ConversationEventProjector.projectMessagesWithMetrics(
            baseMessages: baseMessages,
            events: events,
            frontierEventID: frontier
        )
    }

    /// Harness ``latestValidCheckpoint(id:kind:)`` dispatch across checkpoint taxonomy.
    func latestValidCheckpoint(
        kind: ConversationHarnessCheckpointKind,
        events: [CachedConversationEvent],
        rawMiddle: [Message],
        compactionConfig: ContextCompactionConfiguration,
        rawMessages: [Message]? = nil,
        expectedCompactionStrategyRawValue: String? = nil,
        expectedMemoryStoreVersion: Int? = nil,
        expectedSystemPromptAssemblyFingerprint: String? = nil,
        expectedAttachmentProjectionFingerprint: String? = nil,
        frontierEventID: Int?
    ) -> LatestCheckpointSelection? {
        LatestValidConversationCheckpoint.latestValid(
            kind: kind,
            events: events,
            rawMiddle: rawMiddle,
            compactionConfig: compactionConfig,
            toolTrimConfigFingerprint: ToolResultTrimCheckpointPolicy.configFingerprint,
            rawMessages: rawMessages ?? rawMiddle,
            expectedCompactionStrategyRawValue: expectedCompactionStrategyRawValue,
            expectedMemoryStoreVersion: expectedMemoryStoreVersion,
            expectedSystemPromptAssemblyFingerprint: expectedSystemPromptAssemblyFingerprint,
            expectedAttachmentProjectionFingerprint: expectedAttachmentProjectionFingerprint,
            frontierEventID: frontierEventID
        )
    }

    /// Latest valid harness checkpoint for REST (`GET …/checkpoints/latest?kind=`).
    /// - Parameter harnessCheckpointKind: Harness discriminant (see ``ConversationHarnessCheckpointKind``); omit → `context_compaction`.
    func latestCheckpointResponse(
        conversationID: UUID,
        compactionConfig: ContextCompactionConfiguration,
        harnessCheckpointKind: String? = nil
    ) -> LatestCheckpointResponse? {
        let resolved = harnessCheckpointKind ?? ConversationHarnessCheckpointKind.contextCompaction.rawValue
        guard let kind = ConversationHarnessCheckpointKind(rawValue: resolved) else { return nil }
        guard let rawMsgs = rawMessages(conversationID: conversationID) else { return nil }
        guard let conversation = modelConversation(id: conversationID) else { return nil }
        let modelLimit = conversation.model.maxContextLength ?? compactionConfig.fallbackContextLimitTokens
        let rawMiddle = ContextCompactionCheckpointSupport.rawMiddle(
            from: rawMsgs,
            config: compactionConfig,
            modelContextLimitTokens: modelLimit
        )
        let (events, frontier) = loadConversationEventsWithFrontier(conversationID: conversationID)
        guard let selection = latestValidCheckpoint(
            kind: kind,
            events: events,
            rawMiddle: rawMiddle,
            compactionConfig: compactionConfig,
            rawMessages: rawMsgs,
            frontierEventID: frontier
        ) else {
            return nil
        }
        return selection.toResponse()
    }

    /// Transcript-derived run history (runs.md); v2 JSONL only.
    /// `running` rows reconcile with the active streaming runtime id.
    func runIDsRequiringDurableOrphanRepair(
        conversationID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?
    ) -> [UUID] {
        guard let conversation = modelConversation(id: conversationID) else { return [] }
        guard let entries = try? harnessSessionPersistence.readTranscriptEntries(conversationID: conversationID, request: .full)
        else {
            return []
        }
        return TranscriptRunDerivation.runIDsRequiringOrphanRepair(
            sortedEntries: entries,
            persistedCurrentRunID: conversation.currentRunID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            conversationID: conversationID
        )
    }

    func projectedRunsForAPI(
        conversationID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        filter: ConversationRunListFilter,
        includeProjectionDetail: Bool = false
    ) -> ConversationRunListResponse {
        guard modelConversation(id: conversationID) != nil else { return ConversationRunListResponse(runs: []) }
        guard let entries = try? harnessSessionPersistence.readTranscriptEntries(conversationID: conversationID, request: .full)
        else {
            return ConversationRunListResponse(runs: [])
        }
        let (events, _) = loadConversationEventsWithFrontier(conversationID: conversationID)
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(events: events)
        let derived = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            includeProjectionDetail: includeProjectionDetail,
            authoritativeUsageRollupsByRunID: rollups
        )
        return TranscriptRunDerivation.listConversationRuns(
            derivedRunsNewestFirst: derived,
            sortedEntries: entries,
            filter: filter
        )
    }

    func projectedRunForAPI(
        conversationID: UUID,
        runID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        includeProjectionDetail: Bool = false
    ) -> ConversationRunInfo? {
        guard modelConversation(id: conversationID) != nil else { return nil }
        guard let entries = try? harnessSessionPersistence.readTranscriptEntries(conversationID: conversationID, request: .full)
        else {
            return nil
        }
        let (events, _) = loadConversationEventsWithFrontier(conversationID: conversationID)
        let rollups = TranscriptRunDerivation.authoritativeUsageRollupsByRun(events: events)
        let derived = TranscriptRunDerivation.deriveConversationRuns(
            sortedEntries: entries,
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            includeProjectionDetail: includeProjectionDetail,
            authoritativeUsageRollupsByRunID: rollups
        )
        return derived.first(where: { $0.id == runID })
    }
}
