import Foundation
import SwiftAgentKit

struct ResponseCachingLLM: LLMProtocol, AdapterAuthProbing {
    let base: any LLMProtocol
    let store: ResponseCacheStore
    let modelID: UUID
    let providerScopeKey: String
    let policy: ResponseCachePolicy

    var currentState: LLMRuntimeState { base.currentState }
    var stateUpdates: AsyncStream<LLMRuntimeState> { base.stateUpdates }
    func getModelName() -> String { base.getModelName() }
    func getCapabilities() -> [LLMCapability] { base.getCapabilities() }
    func getRequestFeatures() -> ModelRequestFeatures { base.getRequestFeatures() }
    func validateAuth() async -> Bool {
        guard let probe = base as? any AdapterAuthProbing else { return true }
        return await probe.validateAuth()
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        guard case .enabled(let maxEntries, let ttlSeconds, let stablePrefixMessageCount) = policy,
              isCacheEligibleRequest(messages: messages)
        else {
            return try await base.send(messages, config: config)
        }

        let key = ResponseCacheKey.make(
            modelID: modelID,
            providerScopeKey: providerScopeKey,
            messages: messages,
            config: config,
            stablePrefixMessageCount: stablePrefixMessageCount
        )
        if let cached = await store.lookup(key: key, ttlSeconds: ttlSeconds) {
            return cached
        }

        let response = try await base.send(messages, config: config)
        if isCacheEligibleResponse(response) {
            await store.insert(
                key: key,
                response: response,
                maxEntries: maxEntries,
                ttlSeconds: ttlSeconds
            )
        }
        return response
    }

    func generateImage(_ config: ImageGenerationRequestConfig) async throws -> ImageGenerationResponse {
        try await base.generateImage(config)
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        base.stream(messages, config: config)
    }

    private func isCacheEligibleRequest(messages: [Message]) -> Bool {
        // Conservative gate: skip requests containing direct tool outputs.
        for message in messages where String(describing: message.role) == "tool" {
            return false
        }
        return true
    }

    private func isCacheEligibleResponse(_ response: LLMResponse) -> Bool {
        response.toolCalls.isEmpty
    }
}

