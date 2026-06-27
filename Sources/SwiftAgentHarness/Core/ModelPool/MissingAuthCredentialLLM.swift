import Foundation
import SwiftAgentKit

/// Placeholder adapter when an auth-required provider binding has no resolvable credentials.
struct MissingAuthCredentialLLM: LLMProtocol {
    let providerID: ProviderID
    let endpointModelId: String

    nonisolated var currentState: LLMRuntimeState { .idle(.ready) }
    nonisolated var stateUpdates: AsyncStream<LLMRuntimeState> { AsyncStream { $0.finish() } }
    nonisolated func getModelName() -> String { endpointModelId }
    nonisolated func getCapabilities() -> [LLMCapability] { [.completion] }
    nonisolated func getRequestFeatures() -> ModelRequestFeatures { .unknown }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        let _ = (messages, config)
        throw LLMError.authenticationFailed
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        let _ = config
        throw LLMError.authenticationFailed
    }

    nonisolated func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        let _ = (messages, config)
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.authenticationFailed)
        }
    }
}
