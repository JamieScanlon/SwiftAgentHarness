//
//  Orchestrator-facing aliases on the composition root (`Sendable` stack); mirrored on
//  ``ConversationPersistenceDomain`` for injection. ``HarnessRuntimeSession`` routes persistence here during orchestration peel-off.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftData

extension ConversationPersistenceStack {

    func routingSaveMessage(
        _ message: Message,
        for conversationID: UUID,
        resourceManager: ResourceManager?,
        logger: Logger?,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) throws -> Message {
        try saveMessage(
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
        try appendMessageJournalEntries(
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
        try appendInteractionModeChangedEvent(
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
        try appendCheckpointInvalidation(
            conversationID: conversationID,
            kinds: kinds,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }

    func routingRevertConversationPreservingPrefixThroughUserMessage(
        conversationID: UUID,
        userMessageID: UUID
    ) throws -> [Message] {
        try revertConversationPreservingPrefixThroughUserMessage(
            conversationID: conversationID,
            userMessageID: userMessageID
        )
    }

    func routingRevertConversationPreservingPrefixThroughMessage(
        conversationID: UUID,
        messageID: UUID
    ) throws -> [Message] {
        try revertConversationPreservingPrefixThroughMessage(
            conversationID: conversationID,
            messageID: messageID
        )
    }

    func routingRevertActiveBranchRemovingAssistantMessage(
        conversationID: UUID,
        assistantMessageID: UUID
    ) throws -> [Message] {
        try revertActiveBranchRemovingAssistantMessage(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID
        )
    }

    func routingPersistRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws {
        try persistRunLifecycleTranscriptMarker(conversationID: conversationID, payload: payload)
    }

    func routingPersistToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int? = nil
    ) throws {
        try persistToolAuditLifecycleEvent(
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
        try persistToolUsageSummaryEvent(
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
        try appendTurnSummaryEvent(
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
        try appendTurnFinalizedEvent(
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
        try persistCompletionAnnounceEvent(
            conversationID: conversationID,
            payload: payload,
            expectedDerivedSequence: expectedDerivedSequence
        )
    }
}
