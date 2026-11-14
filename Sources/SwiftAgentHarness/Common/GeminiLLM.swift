import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Gemini over its Interactions API. Responses arrive whole; `stream` delivers each as one completion.
struct GeminiLLM: LLMProtocol, AdapterAuthProbing {
    private let interactionsURL: URL
    private let modelsURL: URL
    private let apiKey: String
    private let model: String
    private let capabilities: [LLMCapability]
    private let requestFeatures: ModelRequestFeatures
    private let systemPrompt: SystemPrompt?
    private let logger: Logger?
    private let transport: ProviderHTTPStatus.Transport

    init(
        baseURL: URL,
        apiKey: String,
        model: String,
        capabilities: [LLMCapability] = [.unknown],
        requestFeatures: ModelRequestFeatures = .unknown,
        systemPrompt: SystemPrompt? = nil,
        logger: Logger? = nil,
        transport: ProviderHTTPStatus.Transport? = nil
    ) {
        interactionsURL = baseURL.appendingPathComponent("interactions")
        modelsURL = baseURL.appendingPathComponent("models")
        self.apiKey = apiKey
        self.model = model
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.systemPrompt = systemPrompt
        self.logger = logger
        self.transport = transport ?? ProviderHTTPStatus.liveTransport
    }

    func getModelName() -> String { model }

    func getCapabilities() -> [LLMCapability] { capabilities }

    func getRequestFeatures() -> ModelRequestFeatures { requestFeatures }

    func validateAuth() async -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (_, response) = try await transport(request)
            return response.statusCode != 401 && response.statusCode != 403
        } catch {
            logger?.warning("Gemini auth probe request failed (treated as indeterminate/allow): \(error)")
            return true
        }
    }

    func send(_ messages: [Message], config: LLMRequestConfig) async throws -> LLMResponse {
        guard capabilities.contains(.completion) || capabilities.contains(.unknown) else {
            throw LLMError.unsupportedCapability(.completion)
        }
        var request = URLRequest(url: interactionsURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ProviderHTTPStatus.encode(try await requestBody(messages, config: config))
        let data: Data
        do {
            let (received, response) = try await transport(request)
            try ProviderHTTPStatus.validate(response, body: received, provider: "Gemini")
            data = received
        } catch let error as LLMError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.networkError(error)
        }
        let decoded = try GeminiInteractionsCodec.decode(try ProviderHTTPStatus.decode(data))
        let metadata = LLMTokenMetadataBuilder.build(
            inputTokens: decoded.usage?.inputTokens,
            outputTokens: decoded.usage?.outputTokens,
            remainingContextTokens: nil,
            totalTokens: decoded.usage?.totalTokens,
            contextWindowTokens: config.maxTokens,
            cacheReadTokens: decoded.usage?.cachedTokens,
            usageIsProviderReported: decoded.usage != nil,
            finishReason: decoded.finishReason
        )
        return LLMResponse.llmResponse(from: decoded.content, availableTools: config.availableTools)
            .appending(toolCalls: decoded.toolCalls)
            .updatingMetadata(with: metadata)
    }

    func stream(_ messages: [Message], config: LLMRequestConfig) -> AsyncThrowingStream<StreamResult<LLMResponse, LLMResponse>, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var emitter = NormalizedStreamEmitter(continuation: continuation, supportsEagerToolInputStreaming: false)
                do {
                    let response = try await send(messages, config: config)
                    emitter.finishSuccess(
                        content: response.content,
                        toolCalls: response.toolCalls,
                        availableTools: config.availableTools,
                        metadata: response.metadata
                    )
                } catch is CancellationError {
                    emitter.finishCancelled()
                } catch {
                    emitter.finishFailed(with: error)
                }
            }
        }
    }

    /// Test hook: the Interactions body a request sends (no network).
    func requestBody(_ messages: [Message], config: LLMRequestConfig) async throws -> JSON {
        let plan = try await SystemPromptDispatchCodec.resolve(
            messages: messages,
            systemPrompt: systemPrompt,
            promptMetadata: SystemPromptDispatchCodec.extractPromptMetadata(from: config.additionalParameters),
            providerStablePrefix: SystemPromptDispatchCodec.extractProviderStablePrefix(from: config.additionalParameters)
        )
        return GeminiInteractionsCodec.requestBody(model: model, messages: plan.resolvedMessages, config: config)
    }
}
