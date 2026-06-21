import Foundation
import SwiftAgentKit

extension HarnessRuntimeSession {

    internal func update(conversation: ModelConversation) async {
        await conversationMessagingRuntimeService.update(conversation: conversation)
    }

    internal func saveMessageToCache(
        _ message: Message,
        for conversationID: UUID,
        expectedPreviousTailHarnessMessageID: UUID? = nil,
        transcriptRunID: UUID? = nil
    ) async throws -> Message {
        try await conversationMessagingRuntimeService.saveMessageToCache(
            message,
            for: conversationID,
            expectedPreviousTailHarnessMessageID: expectedPreviousTailHarnessMessageID,
            transcriptRunID: transcriptRunID
        )
    }

    internal func appendMessagesToConversation(_ messages: [Message], conversationID: UUID) async {
        await conversationMessagingRuntimeService.appendMessagesToConversation(messages, conversationID: conversationID)
    }

    internal func syncConversationTurnsInCache(
        conversationID: UUID,
        interactionMode: InteractionMode,
        preferredTurns: [ConversationTurn]? = nil
    ) async throws {
        try await persistenceDomain.syncConversationTurnsInCache(
            conversationID: conversationID,
            interactionMode: interactionMode,
            preferredTurns: preferredTurns
        )
    }

    internal func applyStreamingUserCancellation(conversationID: UUID) async {
        await conversationMessagingRuntimeService.applyStreamingUserCancellation(conversationID: conversationID)
    }

    internal func drainPendingSlashCommandsIfNeeded(conversationID: UUID) async {
        await slashCommandDispatchService.drainPendingSlashCommandsIfNeeded(conversationID: conversationID)
    }

    internal func applyTurnSummaryTransformIfNeeded(conversationID: UUID) async {
        await conversationMessagingRuntimeService.applyTurnSummaryTransformIfNeeded(conversationID: conversationID)
    }

    internal func stripRunTailAfterAnchorIfNeeded(conversationID: UUID, anchorUserMessageID: UUID) async {
        await conversationMessagingRuntimeService.stripRunTailAfterAnchorIfNeeded(
            conversationID: conversationID,
            anchorUserMessageID: anchorUserMessageID
        )
    }

    internal func applySendFailure(_ error: Error, conversationID: UUID) async {
        await conversationMessagingRuntimeService.applySendFailure(error, conversationID: conversationID)
    }

    internal func rollbackLatestAssistantTurnForRuntime(
        conversationID: UUID,
        assistantMessageID: UUID?
    ) async {
        await conversationMessagingRuntimeService.rollbackLatestAssistantTurnForRuntime(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID
        )
    }

    internal func resolveOrchestratorTargetConversationID() async -> UUID? {
        await conversationMessagingRuntimeService.resolveOrchestratorTargetConversationID()
    }

    internal func updateCurrentConversation(withMessages messages: [Message]) async {
        await conversationMessagingRuntimeService.updateCurrentConversation(withMessages: messages)
    }

    internal func persistDelegateSpendSnapshot(conversationID: UUID) async {
        await conversationMessagingRuntimeService.persistDelegateSpendSnapshot(conversationID: conversationID)
    }

    @inline(__always)
    internal func preserveLatestRuntimeState(conversationID: UUID, conversation: inout ModelConversation) async {
        guard let latest = await persistenceDomain.modelConversation(id: conversationID) else { return }
        conversation.state = latest.state
        conversation.agenticPhase = latest.agenticPhase
        conversation.llmRequestPhase = latest.llmRequestPhase
        conversation.currentRunID = latest.currentRunID
        conversation.controlPlaneRevision = latest.controlPlaneRevision
    }
}
