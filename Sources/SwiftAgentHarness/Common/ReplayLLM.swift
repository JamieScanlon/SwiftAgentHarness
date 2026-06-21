import Foundation
import SwiftAgentKit

/// Deterministic replay backend used for debug conversation reprocessing.
/// It does not call any external LLM service and instead yields scripted message batches.
actor ReplayLLM: LLMProtocol {
    private var messageBatches: [[Message]]
    private var cursor: Int = 0

    init(messageBatches: [[Message]]) {
        self.messageBatches = messageBatches
    }

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }

    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func getModelName() -> String {
        "replay-llm"
    }

    nonisolated func getCapabilities() -> [LLMCapability] {
        [.completion, .tools]
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        guard let batch = nextMessageBatch() else {
            return LLMResponse(content: "", toolCalls: [])
        }
        let firstAssistant = batch.first(where: { $0.role == .assistant })
        let toolCalls = firstAssistant?.toolCalls ?? []
        return LLMResponse(content: firstAssistant?.content ?? "", toolCalls: toolCalls)
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await send(messages, config: config)
                    continuation.yield(.complete(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        throw LLMError.unsupportedCapability(.imageGeneration)
    }

    func peekNextMessageBatch() -> [Message]? {
        guard cursor < messageBatches.count else { return nil }
        return messageBatches[cursor]
    }

    func nextMessageBatch() -> [Message]? {
        guard cursor < messageBatches.count else { return nil }
        let value = messageBatches[cursor]
        cursor += 1
        return value
    }
}
