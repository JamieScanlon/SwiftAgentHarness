//
//  Manager-facing facade over transcript append, journals, derived checkpoints, and SwiftData revert.
//  Implemented by ``ConversationPersistenceStack`` (attached to ``ConversationManager``); orchestrator aliases also appear on ``ConversationPersistenceDomain``.
//

import Foundation
import Logging
import SwiftAgentKit
import SwiftData

/// Harness-shaped persistence routing for orchestration (see ``TranscriptConversationJournalWriter`` and ``RoutingDerivedEventStore`` for transcript journal I/O).
///
/// Implemented by ``ConversationPersistenceStack``; orchestrator-facing **`routing*`** aliases also surface on
/// ``ConversationPersistenceDomain`` so APILayer/runtime can peel toward **`await`** entry points without doubling through ``HarnessRuntimeSession``.
/// Synchronous **`routing*`** remains for non-actor callers; **`routing*Async`** mirrors on ``ConversationPersistenceDomain`` align ``HarnessRuntimeSession`` with **`await`** ahead of a wholesale protocol reshaping.
protocol ConversationPersistenceCoordinating: AnyObject {

    func saveMessage(
        _ message: Message,
        for conversationID: UUID,
        resourceManager: ResourceManager?,
        logger: Logger?,
        expectedPreviousTailHarnessMessageID: UUID?,
        transcriptRunID: UUID?
    ) throws -> Message

    func appendMessageJournalEntries(
        conversationID: UUID,
        messages: [Message],
        expectedLastMessageId: UUID?
    ) throws

    func appendInteractionModeChangedEvent(
        conversationID: UUID,
        payload: InteractionModeChangedEventPayload,
        expectedRawSequence: Int?
    ) throws

    func appendCheckpointInvalidation(
        conversationID: UUID,
        kinds: [String],
        expectedDerivedSequence: Int?
    ) throws

    func revertConversationPreservingPrefixThroughUserMessage(
        conversationID: UUID,
        userMessageID: UUID
    ) throws -> [Message]

    func revertConversationPreservingPrefixThroughMessage(
        conversationID: UUID,
        messageID: UUID
    ) throws -> [Message]

    func persistRunLifecycleTranscriptMarker(conversationID: UUID, payload: RunLifecycleTranscriptMarkerPayload) throws

    func persistToolAuditLifecycleEvent(
        conversationID: UUID,
        payload: ToolAuditLifecycleEventPayload,
        expectedDerivedSequence: Int?
    ) throws

    func persistToolUsageSummaryEvent(
        conversationID: UUID,
        payload: ToolUsageSummaryEventPayload,
        expectedDerivedSequence: Int?
    ) throws

    func appendTurnSummaryEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        coversStartEventID: Int?,
        coversEndEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func appendTurnFinalizedEvent(
        conversationID: UUID,
        payloadJSON: String,
        basedOnEventID: Int?,
        createdAt: Date,
        expectedDerivedSequence: Int?
    ) throws

    func persistCompletionAnnounceEvent(
        conversationID: UUID,
        payload: CompletionAnnounceEventPayload,
        expectedDerivedSequence: Int?
    ) throws
}

extension ConversationPersistenceStack: ConversationPersistenceCoordinating {}
