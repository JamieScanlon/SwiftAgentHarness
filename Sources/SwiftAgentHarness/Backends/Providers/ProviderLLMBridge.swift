import Foundation
import Logging
import SwiftAgentKit
import OllamaKit

/// Core-owned wire codec construction for provider plugins.
public enum ProviderLLMBridge {
    public static func makeOpenAIAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        OpenAILLM(
            baseURL: context.binding.serverURL.absoluteString,
            apiKey: context.resolvedBearerToken(),
            model: context.binding.endpointModelId,
            capabilities: context.model.capabilities,
            requestFeatures: context.model.requestFeatures,
            systemPrompt: context.systemPrompt,
            logger: context.logger,
            supportsEagerToolInputStreaming: context.supportsEagerToolInputStreaming
        )
    }

    public static func makeAnthropicAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        AnthropicLLM(
            apiURL: context.binding.serverURL,
            apiKey: context.resolvedBearerToken(),
            model: context.binding.endpointModelId,
            capabilities: context.model.capabilities,
            requestFeatures: context.model.requestFeatures,
            systemPrompt: context.systemPrompt,
            logger: context.logger,
            supportsEagerToolInputStreaming: context.supportsEagerToolInputStreaming
        )
    }

    public static func makeOllamaAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        OllamaLLM(
            model: context.binding.endpointModelId,
            serverURL: context.binding.serverURL,
            capabilities: context.model.capabilities,
            requestFeatures: context.model.requestFeatures,
            systemPrompt: context.systemPrompt,
            logger: context.logger,
            supportsEagerToolInputStreaming: context.supportsEagerToolInputStreaming
        )
    }

    public static func makeLMStudioAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        LMStudioLLM(
            model: context.binding.endpointModelId,
            serverURL: context.binding.serverURL,
            capabilities: context.model.capabilities,
            requestFeatures: context.model.requestFeatures,
            systemPrompt: context.systemPrompt,
            logger: context.logger,
            supportsEagerToolInputStreaming: context.supportsEagerToolInputStreaming
        )
    }

    public static func fetchOllamaModelDetail(
        modelName: String,
        serverURL: URL,
        config: ModelConfig
    ) async throws -> (capabilities: Set<LLMCapability>, maxContextLength: Int?) {
        try await OllamaModelDetailSupport.fetchModelDetail(
            modelName: modelName,
            serverURL: serverURL,
            config: config
        )
    }
}

enum OllamaModelDetailSupport {
    static func fetchModelDetail(
        modelName: String,
        serverURL: URL,
        config: ModelConfig
    ) async throws -> (capabilities: Set<LLMCapability>, maxContextLength: Int?) {
        let ollama = OllamaKit(baseURL: serverURL)
        let data = OKModelInfoRequestData(name: modelName)
        let response = try await ollama.modelInfo(data: data)
        var caps = Set<LLMCapability>()
        for capability in response.capabilities {
            switch capability {
            case .completion: caps.insert(.completion)
            case .tools: caps.insert(.tools)
            case .insert: caps.insert(.insert)
            case .vision: caps.insert(.vision)
            case .embedding: caps.insert(.embedding)
            case .thinking: caps.insert(.thinking)
            case .image: caps.insert(.imageGeneration)
            case .audio: caps.insert(.audio)
            }
        }
        for hardcodedCapability in config.hardcodedCapabilities {
            caps.insert(hardcodedCapability)
        }
        ModelManager.normalizeReasoningCapabilities(&caps)
        let maxContextLength = ModelManager.contextLength(from: response)
        return (caps, maxContextLength)
    }
}

extension ProviderAdapterContext {
    func resolvedBearerToken() -> String {
        if let profile = resolvedCredential, profile.isDispatchReady, profile.authType == .local {
            return ""
        }
        if let profile = resolvedCredential, profile.isDispatchReady, let token = profile.apiKey {
            return token
        }
        if let credential = try? authProfileStore.resolveCredential(
            providerID: binding.canonicalProviderID(),
            authProfileLabel: binding.authProfile
        ) {
            return credential.bearerToken
        }
        if (try? ProviderRegistry.manifest(for: binding.canonicalProviderID()))?.providerAuthChoices.isEmpty == true {
            return ""
        }
        fatalError("makeAdapter invoked without dispatch-ready credential for \(binding.canonicalProviderID())")
    }
}
