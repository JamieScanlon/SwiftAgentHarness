import Combine
import Foundation
import SwiftAgentKit

extension AgentRuntimeSessionService {
    func buildRuntimeMessageStream(for conversationID: UUID?) async throws -> AsyncStream<[Message]> {
        sessionState.messageStreamContinuation?.finish()
        sessionState.messageStreamContinuation = nil

        let conv: ModelConversation
        if let conversationID, let selected = await deps.persistenceDomain.modelConversation(id: conversationID) {
            conv = selected
        } else if let selected = await selection.currentConversation() {
            conv = selected
        } else {
            throw ConversationServiceError.conversationNotFound
        }

        let initial = await selection.projectedMessages(for: conv)
        return AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.storeMessageStreamContinuation(continuation)
                await self.wireMessageStream(continuation: continuation, initial: initial)
            }
        }
    }

    func cancelRuntimeMessageStream() {
        sessionState.messageStreamContinuation?.finish()
        sessionState.messageStreamContinuation = nil
        Task { [weak self] in
            await self?.cancelMessageStreamBridge()
        }
    }

    func wireMessageStream(
        continuation: AsyncStream<[Message]>.Continuation,
        initial: [Message]
    ) async {
        await selection.wireMessageStream(continuation: continuation, initial: initial)
    }

    func cancelMessageStreamBridge() async {
        await selection.cancelMessageStreamBridge()
    }

    private func storeMessageStreamContinuation(_ continuation: AsyncStream<[Message]>.Continuation) {
        sessionState.messageStreamContinuation = continuation
    }
}
