import Foundation
import SwiftAgentKit

/// Wraps an ``LLMProtocol`` to observe completed ``LLMResponse``s (for context token UI).
struct ContextTrackingLLM: LLMProtocol {
    private let baseLLM: any LLMProtocol
    private let onCompleteResponse: @Sendable (LLMResponse, LLMRequestConfig) async -> Void

    init(
        baseLLM: any LLMProtocol,
        onCompleteResponse: @escaping @Sendable (LLMResponse, LLMRequestConfig) async -> Void
    ) {
        self.baseLLM = baseLLM
        self.onCompleteResponse = onCompleteResponse
    }

    var currentState: LLMRuntimeState { baseLLM.currentState }

    var stateUpdates: AsyncStream<LLMRuntimeState> { baseLLM.stateUpdates }

    func getModelName() -> String {
        baseLLM.getModelName()
    }

    func getCapabilities() -> [LLMCapability] {
        baseLLM.getCapabilities()
    }

    func getRequestFeatures() -> ModelRequestFeatures {
        baseLLM.getRequestFeatures()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let response = try await baseLLM.send(messages, config: config)
        await onCompleteResponse(response, config)
        return response
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let upstream = baseLLM.stream(messages, config: config)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await result in upstream {
                        if case .complete(let final) = result {
                            await onCompleteResponse(final, config)
                        }
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await baseLLM.generateImage(config)
    }
}
