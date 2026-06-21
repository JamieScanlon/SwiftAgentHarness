import Foundation
import SwiftAgentKit

// MARK: - Messaging

extension HarnessRuntimeSession {

    internal func touchCurrentMessagesIfSelected(conversationID: UUID, conversation: ModelConversation) async {
        await services.conversationSelectionRuntimeService.touchCurrentMessagesIfSelected(
            conversationID: conversationID,
            conversation: conversation
        )
    }

    internal func setCurrentMessagesProjection(for conversation: ModelConversation) async {
        await services.conversationSelectionRuntimeService.setCurrentMessagesProjection(for: conversation)
    }

    internal func setCurrentMessagesIfSelected(conversationID: UUID, messages: [Message]) async {
        await services.conversationSelectionRuntimeService.setCurrentMessagesIfSelected(
            conversationID: conversationID,
            messages: messages
        )
    }

    internal func reselectAfterDelete(deletedConversationID: UUID) async throws {
        try await services.conversationSelectionRuntimeService.reselectAfterDelete(
            deletedConversationID: deletedConversationID
        )
    }

    internal func listCurrentMessages() async throws -> [Message] {
        guard let currentConversation = await currentConversation() else {
            throw ConversationServiceError.conversationNotFound
        }
        return await projectedMessages(for: currentConversation)
    }

    internal func listMessages(conversationID: UUID) async throws -> [Message] {
        guard let conversation = await persistenceDomain.modelConversation(id: conversationID) else {
            throw ConversationServiceError.conversationNotFound
        }
        return await projectedMessages(for: conversation)
    }

    internal func sendMessageAndStreamResponse(
        _ text: String,
        images: [Message.Image],
        conversationID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        try await agentRuntimeSessionService.sendMessageAndStreamResponse(
            text,
            images: images,
            conversationID: conversationID,
            configuration: configuration
        )
    }

    internal func revertToUserMessageAndStreamResponse(
        conversationID: UUID,
        messageID: UUID,
        configuration: Configuration = .init()
    ) async throws -> ChatStreamResponse {
        try await agentRuntimeSessionService.revertToUserMessageAndStreamResponse(
            conversationID: conversationID,
            messageID: messageID,
            configuration: configuration
        )
    }

    internal func requestTurnLoopStop(conversationID: UUID) async {
        await agentRuntimeSessionService.requestTurnLoopStop(conversationID: conversationID)
    }

    internal func cancelGeneration() {
        Task { await agentRuntimeSessionService.cancelGeneration() }
    }

    internal func cancelActiveRunForAPI(conversationID: UUID, runID: UUID) async throws {
        try await agentRuntimeSessionService.cancelActiveRunForAPI(conversationID: conversationID, runID: runID)
    }

    internal func listRunsForAPI(conversationID: UUID, filter: ConversationRunListFilter) async -> ConversationRunListResponse {
        await agentRuntimeSessionService.listRunsForAPI(conversationID: conversationID, filter: filter)
    }

    internal func getRunForAPI(conversationID: UUID, runID: UUID, includeProjectionDetail: Bool = false) async -> ConversationRunInfo? {
        await agentRuntimeSessionService.getRunForAPI(
            conversationID: conversationID,
            runID: runID,
            includeProjectionDetail: includeProjectionDetail
        )
    }

    internal func wireMessageStream(continuation: AsyncStream<[Message]>.Continuation, initial: [Message]) async {
        await services.conversationSelectionRuntimeService.wireMessageStream(
            continuation: continuation,
            initial: initial
        )
    }

    internal func cancelMessageStreamBridge() async {
        await services.conversationSelectionRuntimeService.cancelMessageStreamBridge()
    }
}
