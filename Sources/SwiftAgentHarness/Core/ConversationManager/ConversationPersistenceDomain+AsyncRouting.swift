//
//  ``async throws`` aliases for synchronous persistence routing — lets ``HarnessRuntimeSession`` ``await``
//  durable hops consistently ahead of a future ``ConversationPersistenceCoordinating`` reshaping.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftData

extension ConversationPersistenceDomain {

    func routingAppendMessageJournalEntriesAsync(
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID? = nil
    ) async throws {
        try routingAppendMessageJournalEntries(
            conversationID: conversationID,
            messages: messages,
            expectedLastMessageId: expectedLastMessageId
        )
    }

    func routingAppendInteractionModeChangedEventAsync(
        conversationID: UUID,
        payload: InteractionModeChangedEventPayload,
        expectedRawSequence: Int?
    ) async throws {
        try routingAppendInteractionModeChangedEvent(
            conversationID: conversationID,
            payload: payload,
            expectedRawSequence: expectedRawSequence
        )
    }

    func routingAppendCheckpointInvalidationAsync(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int? = nil
    ) async throws {
        try routingAppendCheckpointInvalidation(
            conversationID: conversationID,
            kinds: kinds,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func pruneDerivedArtifactsForConversationAsync(
        conversationID: UUID,
        policy: DerivedArtifactRetentionPolicy = DerivedArtifactRetentionPolicy(
            supersededOnly: true,
            pruneOrphans: false,
            batchLimit: 1
        )
    ) async throws -> DerivedArtifactRetentionSweepResult {
        try pruneDerivedArtifactsForConversation(conversationID: conversationID, policy: policy)
    }

    func routingRevertConversationPreservingPrefixThroughUserMessageAsync(
        conversationID: UUID,
        userMessageID: UUID
    ) async throws -> [Message] {
        try routingRevertConversationPreservingPrefixThroughUserMessage(
            conversationID: conversationID,
            userMessageID: userMessageID
        )
    }

    func routingRevertConversationPreservingPrefixThroughMessageAsync(
        conversationID: UUID,
        messageID: UUID
    ) async throws -> [Message] {
        try routingRevertConversationPreservingPrefixThroughMessage(
            conversationID: conversationID,
            messageID: messageID
        )
    }

    func routingPersistRunLifecycleTranscriptMarkerAsync(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) async throws {
        try routingPersistRunLifecycleTranscriptMarker(conversationID: conversationID, payload: payload)
    }

    func routingAppendTurnSummaryEventAsync(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) async throws {
        try routingAppendTurnSummaryEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            coversStartEventID: coversStartEventID,
            coversEndEventID: coversEndEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingAppendTurnFinalizedEventAsync(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int? = nil
    ) async throws {
        try routingAppendTurnFinalizedEvent(
            conversationID: conversationID,
            payloadJSON: payloadJSON,
            basedOnEventID: basedOnEventID,
            createdAt: createdAt,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingPersistCompletionAnnounceEventAsync(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int? = nil
    ) async throws {
        try routingPersistCompletionAnnounceEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func persistSystemPromptAssemblyCheckpointIfNeededAsync(conversationID: UUID, fingerprint: String) async throws {
        try persistSystemPromptAssemblyCheckpointIfNeeded(conversationID: conversationID, fingerprint: fingerprint)
    }

    func applyBackgroundCompactionIfEligibleAsync(conversationID: UUID) async {
        applyBackgroundCompactionIfEligible(conversationID: conversationID)
    }

    func persistToolResultTrimCheckpointIfNeededAsync(
        conversationID: UUID,
        coveredMessageIDs: [UUID],
        trimmedToolCallIDs: [String],
        logger: Logger?
    ) async {
        persistToolResultTrimCheckpointIfNeeded(
            conversationID: conversationID,
            coveredMessageIDs: coveredMessageIDs,
            trimmedToolCallIDs: trimmedToolCallIDs,
            logger: logger
        )
    }
}
