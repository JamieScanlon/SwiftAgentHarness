//
//  Typed async forwards on ``ConversationPersistenceDomain`` — callers must not extract
//  ``ConversationManager`` or ``HarnessSessionPersistence`` across isolation boundaries.
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit
import SwiftData

extension ConversationPersistenceDomain {

    // MARK: - Registry

    func modelConversation(id: UUID) -> ModelConversation? {
        stack.conversationManager.modelConversation(id: id)
    }

    func listConversationInfo() -> [ModelConversation] {
        stack.conversationManager.listConversationInfo()
    }

    func listConversationMetadata(visibility: ConversationCatalogVisibilityFilter = .catalogVisible) -> [ConversationMetadata] {
        stack.conversationManager.listConversationMetadata(visibility: visibility)
    }

    func mostRecentConversation() -> ModelConversation? {
        stack.conversationManager.mostRecentConversation()
    }

    var harnessSessionPersistence: any HarnessSessionPersistence {
        stack.harnessSessionPersistence
    }

    func firstConversation(excluding conversationID: UUID) -> ModelConversation? {
        stack.conversationManager.firstConversation(excluding: conversationID)
    }

    func replaceConversationInRegistry(_ conversation: ModelConversation) {
        stack.conversationManager.replaceConversationInRegistry(conversation)
    }

    func applyRegistryTranscriptTruncation(_ conversation: ModelConversation) {
        stack.conversationManager.applyRegistryTranscriptTruncation(conversation)
    }

    public func resetConversationsFromCatalog(availableModels: [Model]) throws {
        try stack.conversationManager.resetConversationsFromCatalog(availableModels: availableModels)
    }

    public func refreshTranscriptIntegrityFromMaintenance(report: SessionTranscriptIntegrityReport) throws {
        try stack.conversationManager.refreshTranscriptIntegrityFromMaintenance(report: report)
    }

    func budgetLedgerHydrationSeeds() -> [BudgetLedgerHydrationSeed] {
        stack.conversationManager.budgetLedgerHydrationSeeds()
    }

    func evictRegistryForTesting() {
        stack.conversationManager.evictRegistryForTesting()
    }

    var conversations: [ModelConversation] {
        stack.conversationManager.conversations
    }

    // MARK: - Projection / reads

    func projectedMessagesForUI(conversation: ModelConversation) -> [Message] {
        stack.conversationManager.projectedMessagesForUI(conversation: conversation)
    }

    func transcriptBaseMessages(for conversation: ModelConversation) -> [Message] {
        stack.conversationManager.transcriptBaseMessages(for: conversation)
    }

    func projectUIMessagesWithMetrics(
        conversationID: UUID,
        baseMessages: [Message]
    ) -> (messages: [Message], metrics: ConversationProjection.ProjectionMetrics, frontierEventID: Int) {
        stack.conversationManager.projectUIMessagesWithMetrics(
            conversationID: conversationID,
            baseMessages: baseMessages
        )
    }

    func readConversationWithDerived(
        conversationID: UUID,
        projectedConversation: ModelConversation
    ) -> ConversationReadWithDerivedResponse? {
        stack.conversationManager.readConversationWithDerived(
            conversationID: conversationID,
            projectedConversation: projectedConversation
        )
    }

    func projectConversation(
        conversationID: UUID,
        request: ConversationProjectRequest
    ) throws -> ConversationProjectResponse {
        stack.conversationManager.projectConversation(conversationID: conversationID, request: request)
    }

    func projectedRunsForAPI(
        conversationID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        filter: ConversationRunListFilter,
        includeProjectionDetail: Bool = false
    ) -> ConversationRunListResponse {
        stack.conversationManager.projectedRunsForAPI(
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            filter: filter,
            includeProjectionDetail: includeProjectionDetail
        )
    }

    func projectedRunForAPI(
        conversationID: UUID,
        runID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?,
        includeProjectionDetail: Bool = false
    ) -> ConversationRunInfo? {
        stack.conversationManager.projectedRunForAPI(
            conversationID: conversationID,
            runID: runID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID,
            includeProjectionDetail: includeProjectionDetail
        )
    }

    // MARK: - Journal / events

    func loadConversationEventsWithFrontier(conversationID: UUID) -> ([CachedConversationEvent], Int) {
        stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
    }

    func latestConversationEventID(conversationID: UUID) -> Int {
        stack.conversationManager.latestConversationEventID(conversationID: conversationID)
    }

    func latestRawTailMessageID(conversationID: UUID) -> UUID? {
        stack.conversationManager.latestRawTailMessageID(conversationID: conversationID)
    }

    func eventIDForMessage(conversationID: UUID, messageID: UUID?) -> Int? {
        stack.conversationManager.eventIDForMessage(conversationID: conversationID, messageID: messageID)
    }

    func messagesNeedingTranscriptMessageAppendedJournal(
        conversationID: UUID,
        messages: [Message]
    ) throws -> [Message] {
        try stack.conversationManager.messagesNeedingTranscriptMessageAppendedJournal(
            conversationID: conversationID,
            messages: messages
        )
    }

    // MARK: - Persistence mutations

    func persistConversationResourceFields(
        _ conversation: ModelConversation,
        streamingRunIDOverride: UUID?
    ) throws {
        try stack.conversationManager.persistConversationResourceFields(
            conversation,
            streamingRunIDOverride: streamingRunIDOverride
        )
    }

    func persistConversationMetadataToCache(conversationID: UUID, metadata: JSON) throws {
        try stack.conversationManager.persistConversationMetadataToCache(
            conversationID: conversationID,
            metadata: metadata
        )
    }

    func persistBudgetSnapshot(conversationID: UUID, snapshot: ConversationBudgetSnapshot) throws {
        try stack.conversationManager.persistBudgetSnapshot(conversationID: conversationID, snapshot: snapshot)
    }

    func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]? = nil
    ) throws {
        try stack.conversationManager.syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    func syncConversationCatalogStateToSessionBackend(conversation: ModelConversation) throws {
        try stack.conversationManager.syncConversationCatalogStateToSessionBackend(conversation: conversation)
    }

    func updateConversationMetadata(
        conversationID: UUID,
        topic: String?,
        description: String?,
        metadata: JSON? = nil,
        interactionMode: InteractionMode? = nil,
        modeProfileID: String? = nil,
        skipControlPlaneRevisionBump: Bool = false,
        allowHarnessMetadataKeys: Bool = false
    ) throws -> Bool {
        try stack.conversationManager.updateConversationMetadata(
            conversationID: conversationID,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump,
            allowHarnessMetadataKeys: allowHarnessMetadataKeys
        )
    }

    func updateConversationLifecycle(
        conversationID: UUID,
        lifecycle: ConversationLifecycleState
    ) throws {
        try stack.conversationManager.updateConversationLifecycle(
            conversationID: conversationID,
            lifecycle: lifecycle
        )
    }

    func readPlanMarkdown(for conversationID: UUID) throws -> String {
        try stack.conversationManager.readPlanMarkdown(for: conversationID)
    }

    func createConversation(
        with model: Model,
        userSystemPrompt: String,
        topic: String?,
        description: String?,
        metadata: JSON?,
        interactionMode: InteractionMode,
        modeProfileID: String? = nil,
        ownerAccountID: UUID? = nil,
        cwd: String? = nil,
        lineageKind: ConversationLineageKind = .root,
        origin: ConversationOrigin = .user
    ) throws -> ModelConversation {
        try stack.conversationManager.createConversation(
            with: model,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID,
            ownerAccountID: ownerAccountID,
            cwd: cwd,
            lineageKind: lineageKind,
            origin: origin
        )
    }

    func runIDsRequiringDurableOrphanRepair(
        conversationID: UUID,
        activeRuntimeRunID: UUID?,
        activeRuntimeConversationID: UUID?
    ) -> [UUID] {
        stack.conversationManager.runIDsRequiringDurableOrphanRepair(
            conversationID: conversationID,
            activeRuntimeRunID: activeRuntimeRunID,
            activeRuntimeConversationID: activeRuntimeConversationID
        )
    }

    // MARK: - Harness I/O (no harness reference escapes)

    func readTranscriptEntries(
        conversationID: UUID,
        request: SessionTranscriptReadRequest
    ) throws -> [SessionTranscriptEntry] {
        try stack.conversationManager.harnessSessionPersistence.readTranscriptEntries(
            conversationID: conversationID,
            request: request
        )
    }

    func latestTranscriptSequence(conversationID: UUID) throws -> Int? {
        try stack.conversationManager.harnessSessionPersistence.latestTranscriptSequence(
            conversationID: conversationID
        )
    }

    func stampAssistantFinishReasonOnTranscript(
        conversationID: UUID,
        messageID: UUID,
        finishReason: String
    ) throws {
        let harness = stack.conversationManager.harnessSessionPersistence
        let entries = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        guard var entry = entries.first(where: { entry in
            guard entry.type == .message || entry.type == .system else { return false }
            guard let payload = try? MessageTranscriptPayloadCodec.decode(entry.payloadJSON) else { return false }
            return payload.id == messageID
        }) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "assistant entry not found for finishReason stamp")
        }
        let wire = try MessageTranscriptPayloadCodec.decode(entry.payloadJSON)
        guard let message = try SessionTranscriptMapping.messageForReplay(from: entry) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "assistant message replay failed")
        }
        entry.payloadJSON = try MessageTranscriptPayloadCodec.encodePayloadJSON(
            from: message,
            transcriptRunID: wire.transcriptRunID,
            finishReason: finishReason
        )
        try updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
    }

    func updateTranscriptMessagePayload(
        conversationID: UUID,
        message: Message
    ) throws {
        let harness = stack.conversationManager.harnessSessionPersistence
        let entries = try harness.readTranscriptEntries(conversationID: conversationID, request: .full)
        guard var entry = entries.first(where: { entry in
            guard entry.type == .message || entry.type == .system else { return false }
            guard let payload = try? MessageTranscriptPayloadCodec.decode(entry.payloadJSON) else { return false }
            return payload.id == message.id
        }) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "message entry not found for payload update")
        }
        let wire = try MessageTranscriptPayloadCodec.decode(entry.payloadJSON)
        entry.payloadJSON = try MessageTranscriptPayloadCodec.encodePayloadJSON(
            from: message,
            transcriptRunID: wire.transcriptRunID,
            finishReason: wire.finishReason
        )
        try updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
    }

    private func updateTranscriptEntryPayload(conversationID: UUID, entry: SessionTranscriptEntry) throws {
        let harness = stack.conversationManager.harnessSessionPersistence
        switch harness {
        case let local as LocalHarnessSessionPersistence:
            try local.updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
        case let inMemory as InMemoryHarnessSessionPersistence:
            try inMemory.updateTranscriptEntryPayload(conversationID: conversationID, entry: entry)
        default:
            return
        }
    }

    func conversationEventsWithFrontier(conversationID: UUID) -> ([CachedConversationEvent], Int) {
        stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversationID)
    }

    func activeTranscriptMessages(conversationID: UUID) throws -> [Message] {
        try ConversationTranscriptLineage.activeMessages(
            conversationID: conversationID,
            harness: stack.conversationManager.harnessSessionPersistence
        )
    }

    func recordExecDenialHygieneSideEffects(
        conversationID: UUID,
        coveredMessageIDs: [UUID],
        trimmedToolCallIDs: [String],
        logger: Logger?
    ) throws {
        persistToolResultTrimCheckpointIfNeeded(
            conversationID: conversationID,
            coveredMessageIDs: coveredMessageIDs,
            trimmedToolCallIDs: trimmedToolCallIDs,
            logger: logger
        )
        try stack.appendCheckpointInvalidation(
            conversationID: conversationID,
            kinds: [
                HarnessCheckpointInvalidationKind.contextCompaction,
                HarnessCheckpointInvalidationKind.toolResultTrim,
            ]
        )
    }

    func hydrateBlobImages(in messages: [Message], conversationID: UUID) -> [Message] {
        SessionBlobMessageHydration.hydrateBlobImages(
            in: messages,
            harness: stack.conversationManager.harnessSessionPersistence,
            conversationID: conversationID
        )
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) throws -> Bool {
        try stack.conversationManager.harnessSessionPersistence.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }

    func dedupePeek(key: String) throws -> Bool {
        try stack.conversationManager.harnessSessionPersistence.dedupePeek(key: key)
    }

    func appendTaskRun(jobId: String, payload: Data, idempotencyKey: String?) throws -> UUID {
        try stack.conversationManager.sessionBackend.appendTaskRun(jobId: jobId, payload: payload, idempotencyKey: idempotencyKey)
    }

    func latestUndeliveredTaskRun(jobId: String) throws -> SessionHarnessTaskRunRecord? {
        try stack.conversationManager.sessionBackend.latestUndeliveredTaskRun(jobId: jobId)
    }

    func markTaskRunDelivered(runId: UUID) throws {
        try stack.conversationManager.sessionBackend.markTaskRunDelivered(runId: runId)
    }

    func resolveConversationByTitle(_ title: String) throws -> UUID? {
        try stack.conversationManager.sessionBackend.resolveSessionByTitle(
            title,
            lifecycleState: ConversationLifecycleState.active.rawValue
        )
    }

    func stampTriggerHostConversation(
        conversationID: UUID,
        trigger: HarnessTrigger,
        sessionKey: String
    ) throws {
        try stack.conversationManager.stampTriggerHostConversation(
            conversationID: conversationID,
            trigger: trigger,
            sessionKey: sessionKey
        )
    }

    func softDeleteConversation(conversationID: UUID) throws {
        try stack.conversationManager.softDeleteConversation(conversationID: conversationID)
    }

    func deleteConversation(conversationID: UUID) throws {
        try stack.conversationManager.deleteConversation(conversationID: conversationID)
    }

    func copyConversation(from sourceConversationID: UUID, to model: Model, systemPrompt: String) throws -> ModelConversation {
        try stack.conversationManager.copyConversation(
            from: sourceConversationID,
            to: model,
            systemPrompt: systemPrompt
        )
    }

    func latestCheckpointResponse(
        conversationID: UUID,
        compactionConfig: ContextCompactionConfiguration,
        harnessCheckpointKind: String? = nil
    ) -> LatestCheckpointResponse? {
        stack.conversationManager.latestCheckpointResponse(
            conversationID: conversationID,
            compactionConfig: compactionConfig,
            harnessCheckpointKind: harnessCheckpointKind
        )
    }

    func persistSplitSelectingNewThread(
        sourceConversation: ModelConversation,
        atUserMessageID messageID: UUID,
        childLineageKind: ConversationLineageKind = .branch
    ) throws -> (newConversationID: UUID, anchorNewUserMessageID: UUID, newConversation: ModelConversation) {
        try stack.conversationManager.persistSplitSelectingNewThread(
            sourceConversation: sourceConversation,
            atUserMessageID: messageID,
            childLineageKind: childLineageKind
        )
    }

    func bumpControlPlaneRevision(conversationID: UUID) throws {
        try stack.conversationManager.bumpControlPlaneRevision(conversationID: conversationID)
    }

    func updateConversationModelAndUserPrompt(
        conversationID: UUID,
        model: Model?,
        userSystemPrompt: String?,
        skipControlPlaneRevisionBump: Bool = false
    ) throws -> ModelConversation {
        try stack.conversationManager.updateConversationModelAndUserPrompt(
            conversationID: conversationID,
            model: model,
            userSystemPrompt: userSystemPrompt,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    func updateConversationThinkingConfig(
        conversationID: UUID,
        thinkingConfig: ThinkingConfig?,
        skipControlPlaneRevisionBump: Bool = false
    ) throws {
        try stack.conversationManager.updateConversationThinkingConfig(
            conversationID: conversationID,
            thinkingConfig: thinkingConfig,
            skipControlPlaneRevisionBump: skipControlPlaneRevisionBump
        )
    }

    func createIsolatedSubAgent(
        parentConversationID: UUID,
        selectedModel: Model,
        userSystemPrompt: String,
        topic: String? = nil,
        description: String? = nil,
        metadata: JSON? = nil,
        interactionMode: InteractionMode,
        modeProfileID: String? = nil
    ) throws -> ModelConversation {
        try stack.conversationManager.createIsolatedSubAgent(
            parentConversationID: parentConversationID,
            selectedModel: selectedModel,
            userSystemPrompt: userSystemPrompt,
            topic: topic,
            description: description,
            metadata: metadata,
            interactionMode: interactionMode,
            modeProfileID: modeProfileID
        )
    }

    func listEngineArtifactKeys(conversationID: UUID) throws -> [String] {
        try stack.conversationManager.harnessSessionPersistence.listEngineArtifactKeys(conversationID: conversationID)
    }

    func getEngineArtifact(conversationID: UUID, key: String) throws -> Data? {
        try stack.conversationManager.harnessSessionPersistence.getEngineArtifact(conversationID: conversationID, key: key)
    }

    func putEngineArtifact(conversationID: UUID, key: String, data: Data) throws {
        try stack.conversationManager.harnessSessionPersistence.putEngineArtifact(
            conversationID: conversationID,
            key: key,
            data: data
        )
    }

    func evictEngineArtifacts(conversationID: UUID, key: String?) throws {
        try stack.conversationManager.harnessSessionPersistence.evictEngineArtifacts(
            conversationID: conversationID,
            key: key
        )
    }

    func catalogConversation(id: UUID) throws -> SessionCatalogRecord? {
        try stack.conversationManager.sessionBackend.catalogConversation(id: id)
    }

    func sessionTreeTranscriptEntries(conversationID: UUID) throws -> [SessionTranscriptEntry] {
        try ConversationTranscriptLineage.activeLineageEntries(
            conversationID: conversationID,
            harness: stack.conversationManager.harnessSessionPersistence
        )
    }
}
