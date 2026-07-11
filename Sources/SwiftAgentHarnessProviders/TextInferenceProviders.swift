import Foundation
import Logging
import SwiftAgentKit
import OllamaKit
import SwiftAgentHarness

struct LMStudioGetModelsResponse: Codable, Sendable {
    var data: [LMStudioGetModelsResponseData]
}

struct LMStudioGetModelsResponseData: Codable, Sendable {
    var id: String
    var object: String
    var type: String
    var publisher: String
    var arch: String
    var compatibility_type: String
    var quantization: String
    var state: String
    var max_context_length: Int
    var capabilities: [String]?
}

public struct OpenAITextInferenceProvider: TextInferenceProviding {
    public let manifest: ProviderManifest
    public let modelProtocol: ModelProtocol = .openAIAPI

    public init(manifest: ProviderManifest) {
        self.manifest = manifest
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        bundledStaticCatalogEntries(providerID: manifest.id)
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeOpenAIAdapter(context: context)
    }

    public func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility {
        context.endpointModelId.hasPrefix("gpt-") ? .long : .short
    }

    public func selectPromptCacheBreakpoints(
        _ candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        PromptCacheBreakpointSelectionPolicy.implicit(candidates: candidates, context: context)
    }

    public func failoverError(_ error: Error) -> ProviderFailoverClassification {
        if DefaultProviderFailoverClassifier.isCredentialExhausted(error) {
            return .credentialExhausted
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }
}

public struct AnthropicTextInferenceProvider: TextInferenceProviding {
    public let manifest: ProviderManifest
    public let modelProtocol: ModelProtocol = .anthropic

    public init(manifest: ProviderManifest) {
        self.manifest = manifest
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        bundledStaticCatalogEntries(providerID: manifest.id)
    }

    public func normalizeProviderModelId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "opus": return "claude-opus-4-6"
        case "sonnet": return "claude-sonnet-4-6"
        case "haiku": return "claude-haiku-4-5"
        default: return trimmed
        }
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeAnthropicAdapter(context: context)
    }

    public func cacheTtlEligibility(_ context: ProviderSystemPromptContext) -> ProviderCacheTTLEligibility {
        .long
    }

    public func selectPromptCacheBreakpoints(
        _ candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        PromptCacheBreakpointSelectionPolicy.anthropic(candidates: candidates, context: context)
    }

    public func failoverError(_ error: Error) -> ProviderFailoverClassification {
        if DefaultProviderFailoverClassifier.isCredentialExhausted(error) {
            return .credentialExhausted
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }

    public func replayPolicy(_ context: ProviderMessageTransformContext) -> ProviderReplayPolicy {
        .anthropicTarget
    }
}

public struct OllamaTextInferenceProvider: TextInferenceProviding {
    public let manifest: ProviderManifest
    public let modelProtocol: ModelProtocol = .ollama

    public init(manifest: ProviderManifest) {
        self.manifest = manifest
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        Constants.ollamaModelIDMap.map { name, config in
            ProviderCatalogEntry(
                registryID: config.uuid,
                endpointModelId: name,
                displayName: name,
                modelConfig: config
            )
        }
    }

    public func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        let ollama = OllamaKit(baseURL: Constants.ollamaServerURL)
        let response: OKModelResponse
        do {
            response = try await ollama.models()
        } catch {
            logger?.warning("Ollama: failed to list models (/api/tags): \(error)")
            return []
        }
        var entries: [ModelRegistryEntry] = []
        for model in response.models {
            let catalogEntry = await resolveDynamicModel(
                ProviderDynamicModelContext(
                    endpointModelId: model.name,
                    serverURL: Constants.ollamaServerURL
                )
            ) ?? staticCatalogEntries().first(where: { $0.endpointModelId == model.name })
            guard let catalogEntry else {
                logger?.warning("The Ollama model \(model.name) was not found in the provider catalog. Ignoring.")
                continue
            }
            do {
                let detail = try await ProviderLLMBridge.fetchOllamaModelDetail(
                    modelName: model.name,
                    config: catalogEntry.modelConfig
                )
                var entry = catalogEntry.toRegistryEntry(
                    providerID: manifest.id,
                    serverURL: Constants.ollamaServerURL
                )
                entry.capabilities = detail.capabilities
                entry.maxContextLength = detail.maxContextLength
                entries.append(entry)
            } catch {
                logger?.warning("Ollama: modelInfo failed for \(model.name); skipping that model: \(error)")
            }
        }
        return entries
    }

    public func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry? {
        guard let config = Constants.ollamaModelIDMap[context.endpointModelId] else { return nil }
        return ProviderCatalogEntry(
            registryID: config.uuid,
            endpointModelId: context.endpointModelId,
            displayName: context.endpointModelId,
            modelConfig: config
        )
    }

    public func prepareDynamicModel(_ context: ProviderDynamicPrepareContext) async -> ProviderCatalogEntry? {
        var entry = context.catalogEntry
        do {
            let detail = try await ProviderLLMBridge.fetchOllamaModelDetail(
                modelName: context.binding.endpointModelId,
                config: entry.modelConfig
            )
            entry.capabilities = detail.capabilities
            entry.maxContextLength = detail.maxContextLength
        } catch {
            return entry
        }
        return entry
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeOllamaAdapter(context: context)
    }
}

public struct LMStudioTextInferenceProvider: TextInferenceProviding {
    public let manifest: ProviderManifest
    public let modelProtocol: ModelProtocol = .lmStudio

    public init(manifest: ProviderManifest) {
        self.manifest = manifest
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        Constants.lmStudioModelIDMap.map { name, config in
            ProviderCatalogEntry(
                registryID: config.uuid,
                endpointModelId: name,
                displayName: name,
                modelConfig: config
            )
        }
    }

    public func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        let apiManager = RestAPIManager(
            baseURL: Constants.lmStudioServerURL,
            sseTimeoutInterval: 31536000.0,
            logger: logger
        )
        let response: LMStudioGetModelsResponse
        do {
            response = try await apiManager.decodableRequest("api/v0/models")
        } catch {
            logger?.warning(
                "LM Studio: failed to decode GET api/v0/models (is the local server running on \(Constants.lmStudioServerURL.absoluteString)?): \(error)"
            )
            return []
        }
        var entries: [ModelRegistryEntry] = []
        for model in response.data {
            var catalogEntry = staticCatalogEntries().first(where: { $0.endpointModelId == model.id })
            if catalogEntry == nil {
                catalogEntry = await resolveDynamicModel(
                    ProviderDynamicModelContext(
                        endpointModelId: model.id,
                        serverURL: Constants.lmStudioServerURL
                    )
                )
            }
            guard let catalogEntry else {
                logger?.warning("The LMStudio model \(model.id) was not found in the provider catalog. Ignoring.")
                continue
            }
            var capabilities = lmStudioCapabilities(for: model, modelConfig: catalogEntry.modelConfig)
            ModelManager.normalizeReasoningCapabilities(&capabilities)
            var entry = catalogEntry.toRegistryEntry(
                providerID: manifest.id,
                serverURL: Constants.lmStudioServerURL
            )
            entry.capabilities = capabilities
            entry.maxContextLength = model.max_context_length
            entries.append(entry)
        }
        return entries
    }

    public func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry? {
        guard let config = Constants.lmStudioModelIDMap[context.endpointModelId] else { return nil }
        return ProviderCatalogEntry(
            registryID: config.uuid,
            endpointModelId: context.endpointModelId,
            displayName: context.endpointModelId,
            modelConfig: config
        )
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeLMStudioAdapter(context: context)
    }

    public func selectPromptCacheBreakpoints(
        _ candidates: [PromptCacheBreakpointCandidate],
        context: ProviderPromptCacheBreakpointContext
    ) -> ProviderPromptCacheBreakpointPlan {
        PromptCacheBreakpointSelectionPolicy.lmStudio(candidates: candidates, context: context)
    }

    private func lmStudioCapabilities(
        for model: LMStudioGetModelsResponseData,
        modelConfig: ModelConfig
    ) -> Set<LLMCapability> {
        var caps = Set<LLMCapability>()
        if model.type == "llm" || model.type == "vlm" {
            caps.insert(.completion)
        }
        if model.type == "vlm" {
            caps.insert(.vision)
        }
        if model.type == "embeddings" {
            caps.insert(.embedding)
        }
        if let myCapabilities = model.capabilities {
            for capability in myCapabilities {
                switch capability {
                case "tool_use":
                    caps.insert(.tools)
                case "image_generation", "image_output":
                    caps.insert(.imageGeneration)
                default:
                    break
                }
            }
        }
        for hardcodedCapability in modelConfig.hardcodedCapabilities {
            caps.insert(hardcodedCapability)
        }
        return caps
    }
}

public struct OpenRouterTextInferenceProvider: TextInferenceProviding {
    public let modelProtocol: ModelProtocol = .openAIAPI
    public let manifest: ProviderManifest

    public init(manifest: ProviderManifest) {
        self.manifest = manifest
    }

    public func staticCatalogEntries() -> [ProviderCatalogEntry] {
        bundledStaticCatalogEntries(providerID: manifest.id)
    }

    public func discoverEntries(logger: Logger?) async -> [ModelRegistryEntry] {
        await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: manifest,
            staticEntries: staticCatalogEntries(),
            logger: logger
        )
    }

    public func resolveDynamicModel(_ context: ProviderDynamicModelContext) async -> ProviderCatalogEntry? {
        OpenRouterCatalogDiscovery.resolveDynamicModel(
            context: context,
            providerID: manifest.id,
            staticEntries: staticCatalogEntries()
        )
    }

    public func preferRuntimeResolvedModel(_ context: ProviderDynamicModelPreferenceContext) -> Bool {
        true
    }

    public func makeAdapter(context: ProviderAdapterContext) -> any LLMProtocol {
        ProviderLLMBridge.makeOpenAIAdapter(context: context)
    }

    public func failoverError(_ error: Error) -> ProviderFailoverClassification {
        if DefaultProviderFailoverClassifier.isCredentialExhausted(error) {
            return .credentialExhausted
        }
        return DefaultProviderFailoverClassifier.classify(error)
    }
}
