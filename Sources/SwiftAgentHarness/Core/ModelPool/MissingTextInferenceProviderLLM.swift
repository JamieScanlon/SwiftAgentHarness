import Foundation
import SwiftAgentKit

/// Placeholder adapter when no text-inference provider is registered for a binding.
struct MissingTextInferenceProviderLLM: LLMProtocol {
    let providerID: ProviderID
    let modelProtocol: ModelProtocol
    let endpointModelId: String

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { endpointModelId }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { .unknown }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        throw LLMError.modelNotFound("\(providerID)/\(modelProtocol.rawValue)/\(endpointModelId)")
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.modelNotFound("\(providerID)/\(modelProtocol.rawValue)/\(endpointModelId)")
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.modelNotFound("\(providerID)/\(modelProtocol.rawValue)/\(endpointModelId)"))
        }
    }
}
