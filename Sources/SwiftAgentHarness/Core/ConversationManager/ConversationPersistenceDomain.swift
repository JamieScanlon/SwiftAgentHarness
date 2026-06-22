//
//  composition-root persistence handle: owns ``ConversationPersistenceStack`` end-to-end.
//  Implemented as an **`actor`** so registry, harness I/O, and journal routing share one serialization point.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftData

public actor ConversationPersistenceDomain {
    let stack: ConversationPersistenceStack

    init(stack: ConversationPersistenceStack) {
        self.stack = stack
    }

    public static func makeProduction(
        logger: Logger?,
        dataStoreURL: URL?,
        allowsSwiftDataSave: Bool
    ) -> ConversationPersistenceDomain {
        ConversationPersistenceDomain(
            stack: ConversationPersistenceStack.makeProduction(
                logger: logger,
                dataStoreURL: dataStoreURL,
                allowsSwiftDataSave: allowsSwiftDataSave
            )
        )
    }

    static func makeForTesting(
        container: ModelContainer,
        logger: Logger?,
        derivedEventStore: (any DerivedEventStore)? = nil,
        harnessSessionPersistenceOverride: (any HarnessSessionPersistence)? = nil
    ) -> ConversationPersistenceDomain {
        ConversationPersistenceDomain(
            stack: ConversationPersistenceStack.makeForTesting(
                container: container,
                logger: logger,
                derivedEventStore: derivedEventStore,
                harnessSessionPersistenceOverride: harnessSessionPersistenceOverride
            )
        )
    }

    func applyContextAssemblyPersistence(
        result: ContextEngineAssembleResult,
        assembleRequest: ContextEngineAssembleRequest,
        logger: Logger?,
        scope: ContextAssemblyDerivedCheckpointScope,
        persistMemoryAndFlushCheckpoints: Bool
    ) -> ContextAssemblyPersistenceSideEffects {
        ContextAssemblyPersistenceApplicator.apply(
            result: result,
            assembleRequest: assembleRequest,
            persistence: stack,
            logger: logger,
            scope: scope,
            persistMemoryAndFlushCheckpoints: persistMemoryAndFlushCheckpoints
        )
    }

    func persistSystemPromptAssemblyCheckpointIfNeeded(
        conversationID: UUID,
        fingerprint: String
    ) throws {
        try ContextCheckpointWriter.persistSystemPromptAssemblyCheckpointIfNeeded(
            conversationID: conversationID,
            fingerprint: fingerprint,
            persistence: stack
        )
    }

    func persistToolResultTrimCheckpointIfNeeded(
        conversationID: UUID,
        coveredMessageIDs: [UUID],
        trimmedToolCallIDs: [String],
        logger: Logger?
    ) {
        ContextCheckpointWriter.persistToolResultTrimCheckpointIfNeeded(
            conversationID: conversationID,
            coveredMessageIDs: coveredMessageIDs,
            trimmedToolCallIDs: trimmedToolCallIDs,
            persistence: stack,
            logger: logger
        )
    }

    func applyBackgroundCompactionIfEligible(conversationID: UUID) {
        stack.applyBackgroundCompactionIfEligible(conversationID: conversationID)
    }

    func makeContextEngineAssembleRequest(
        messages: [Message],
        conversation: ModelConversation,
        phase: ContextTransformInvocationPhase,
        gatingOverride: ContextCompactionGatingOptions?,
        compactionCustomInstructionsOverride: String?,
        enableContextTransform: Bool,
        persistCompactionCheckpoint: Bool,
        allowProactiveCompactionTriggers: Bool,
        compactionLockAlreadyHeldByCaller: Bool,
        projectionPolicy: ContextEngineProjectionPolicyInput?,
        lastContextLimitTokens: Int?,
        lastPromptTokens: Int?,
        lastContextCompactionLLMDateByConversationID: [UUID: Date],
        conversationTransformConfiguration: ConversationTransformConfiguration
    ) -> ContextEngineAssembleRequest {
        let (events, frontier) = stack.conversationManager.loadConversationEventsWithFrontier(conversationID: conversation.id)
        let derivedTailAtProjectionStart = events
            .filter { $0.journalStreamRaw == ConversationJournalStream.derived.rawValue }
            .map(\.streamSequence)
            .max() ?? 0
        let preCompactionMemoryFlushPolicy = ContextCompactionPolicy.resolvedPreCompactionMemoryFlushPolicy(
            config: conversationTransformConfiguration.contextCompaction
        )
        return ContextEngineAssembleRequest(
            messages: messages,
            conversation: conversation,
            phase: phase,
            gatingOverride: gatingOverride,
            compactionCustomInstructionsOverride: compactionCustomInstructionsOverride,
            enableContextTransform: enableContextTransform,
            compactionConfig: conversationTransformConfiguration.contextCompaction,
            transformMetadata: ContextAssemblyService.conversationTransformMetadata(for: conversation),
            lastContextLimitTokens: lastContextLimitTokens,
            lastPromptTokens: lastPromptTokens,
            events: events,
            eventLogFrontier: frontier,
            lastLLMDateByConversationID: lastContextCompactionLLMDateByConversationID,
            persistCompactionCheckpoint: persistCompactionCheckpoint,
            allowProactiveCompactionTriggers: allowProactiveCompactionTriggers,
            compactionLockAlreadyHeldByCaller: compactionLockAlreadyHeldByCaller,
            derivedTailAtProjectionStart: derivedTailAtProjectionStart,
            projectionPolicy: projectionPolicy,
            preCompactionMemoryFlushPolicy: preCompactionMemoryFlushPolicy
        )
    }

    // MARK: - Routing aliases (orchestrator persistence)

    func routingSaveMessage(
        _ message: Message,
        for conversationID: UUID,
        resourceManager: ResourceManager?,
        logger: Logger?,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) throws -> Message {
        try stack.routingSaveMessage(
            message,
            for: conversationID,
            resourceManager: resourceManager,
            logger: logger,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            transcriptRunID: transcriptRunID
        )
    }

    func routingAppendMessageJournalEntries(
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID? = nil
    ) throws {
        try stack.routingAppendMessageJournalEntries(
            conversationID: conversationID,
            messages: messages,
            expectedLastMessageId: expectedLastMessageId
        )
    }

    func routingAppendInteractionModeChangedEvent(
        conversationID: UUID,
        payload: InteractionModeChangedEventPayload,
        expectedRawSequence: Int?
    ) throws {
        try stack.routingAppendInteractionModeChangedEvent(
            conversationID: conversationID,
            payload: payload,
            expectedRawSequence: expectedRawSequence
        )
    }

    func routingAppendCheckpointInvalidation(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingAppendCheckpointInvalidation(
            conversationID: conversationID,
            kinds: kinds,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingRevertConversationPreservingPrefixThroughUserMessage(
        conversationID: UUID,
        userMessageID: UUID
    ) throws -> [Message] {
        try stack.routingRevertConversationPreservingPrefixThroughUserMessage(
            conversationID: conversationID,
            userMessageID: userMessageID
        )
    }

    func routingRevertConversationPreservingPrefixThroughMessage(
        conversationID: UUID,
        messageID: UUID
    ) throws -> [Message] {
        try stack.routingRevertConversationPreservingPrefixThroughMessage(
            conversationID: conversationID,
            messageID: messageID
        )
    }

    func routingPersistRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        try stack.routingPersistRunLifecycleTranscriptMarker(conversationID: conversationID, payload: payload)
    }

    func routingPersistToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingPersistToolAuditLifecycleEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingPersistToolUsageSummaryEvent(
        conversationID: UUID,
        payload: ToolUsageSummaryEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingPersistToolUsageSummaryEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingAppendTurnSummaryEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingAppendTurnSummaryEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingAppendTurnFinalizedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingAppendTurnFinalizedEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingPersistCompletionAnnounceEvent(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try stack.routingPersistCompletionAnnounceEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    // MARK: - Persisted queries & maintenance (orchestration peel)

    func listConversationSummaries(query: ConversationListQuery) -> PagedConversationsResponse {
        stack.conversationManager.listConversationSummaries(query: query)
    }

    func searchConversations(request: ConversationSearchRequest) -> ConversationSearchResponse {
        stack.conversationManager.searchConversations(request: request)
    }

    func runDerivedArtifactRetentionSweep(policy: DerivedArtifactRetentionPolicy) throws -> DerivedArtifactRetentionSweepResult {
        let catalogIDs = Set(
            (try? stack.conversationManager.sessionBackend.listCatalogConversations())?.map(\.id) ?? []
        )
        return try DerivedArtifactRetentionWorker(
            harness: stack.conversationManager.harnessSessionPersistence
        ).runSweep(
            policy: policy,
            knownConversationIDs: catalogIDs.isEmpty ? nil : catalogIDs
        )
    }

    func pruneDerivedArtifactsForConversation(
        conversationID: UUID,
        policy: DerivedArtifactRetentionPolicy = DerivedArtifactRetentionPolicy(
            supersededOnly: true,
            pruneOrphans: false,
            batchLimit: 1
        )
    ) throws -> DerivedArtifactRetentionSweepResult {
        try DerivedArtifactRetentionWorker(
            harness: stack.conversationManager.harnessSessionPersistence
        ).runSweep(
            policy: policy,
            knownConversationIDs: [conversationID]
        )
    }
}
