import Combine
import Foundation
import Logging
import OllamaKit
import SwiftAgentKit

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

public actor ModelManager {

    @Published var activeModels: [Model] = []
    var logger: Logger?

    /// Canonical registry keyed by stable model UUID (Phase 1 model pool).
    private var registryByID: [UUID: ModelRegistryEntry] = [:]

    /// Lookup by canonical slug (primary `endpointModelId`) and any additional binding slugs.
    /// First-seen wins on collision; collisions are logged as warnings.
    private var slugIndex: [String: UUID] = [:]

    /// When set, publishes granular `models/registry` change events on ``ResourceTopicName/modelsRegistry``
    /// and refreshes the hub's cached snapshot so new subscribers see the latest models.
    private let registryTopicHub: (any ModelPoolResourceTopicPublishing)?
    /// Last registry snapshot we published, keyed by canonical model UUID. Empty until the first
    /// successful discovery sync. Diffed against each new snapshot via ``ModelRegistryDiff``.
    private var lastPublishedRegistryByID: [UUID: Model] = [:]
    /// Optional provider for runtime-observed performance overlays.
    private var observedPerformanceProvider: (@Sendable (UUID) async -> ModelObservedPerformance?)?

    public init(
        logger: Logger? = nil,
        registryTopicHub: (any ModelPoolResourceTopicPublishing)? = nil,
        observedPerformanceProvider: (@Sendable (UUID) async -> ModelObservedPerformance?)? = nil
    ) {
        self.logger = logger
        self.registryTopicHub = registryTopicHub
        self.observedPerformanceProvider = observedPerformanceProvider
    }

    /// Discovers models from Ollama and LM Studio, merges into the registry, and returns DTOs.
    public func getAvailableModels() async -> [Model] {
        await syncRegistryFromDiscovery()
        return sortedModelsFromRegistry()
    }

    /// Full registry rows (preserves family / providers / cost / useClasses for routing-aware callers).
    public func getRegistryEntries() async -> [ModelRegistryEntry] {
        await syncRegistryFromDiscovery()
        return registryByID.values
            .sorted { ($0.displayName ?? $0.id.uuidString) < ($1.displayName ?? $1.id.uuidString) }
    }

    /// Canonical resolve: O(1) for `.id` and `.slug` via the registry indexes; ranked candidates for `.query`.
    /// Throws ``ModelPoolError/unavailable(reference:)`` when no entry matches.
    public func resolve(_ ref: ModelReference) async throws -> ModelRegistryEntry {
        await syncRegistryFromDiscovery()
        switch ref {
        case .id(let id):
            if let entry = registryByID[id] { return entry }
        case .slug(let slug):
            if let id = slugIndex[slug], let entry = registryByID[id] { return entry }
        case .query(let query):
            let entries = Array(registryByID.values)
            if let hit = ModelQuery.rank(entries: entries, query: query).first { return hit }
        }
        throw ModelPoolError.unavailable(reference: ref)
    }

    /// Canonical bulk resolve: `.id` / `.slug` return a single-element list (or throw `.unavailable`);
    /// `.query` returns the ranked candidate set (empty array when filters drop everything — does not throw).
    public func resolveAll(_ ref: ModelReference) async throws -> [ModelRegistryEntry] {
        switch ref {
        case .id, .slug:
            return [try await resolve(ref)]
        case .query(let query):
            await syncRegistryFromDiscovery()
            let entries = Array(registryByID.values)
            return ModelQuery.rank(entries: entries, query: query)
        }
    }

    private func syncRegistryFromDiscovery() async {
        var merged: [UUID: ModelRegistryEntry] = [:]
        for entry in await discoverOllamaEntries() {
            merged[entry.id] = entry
        }
        for entry in await discoverLMStudioEntries() {
            merged[entry.id] = entry
        }
        if let observedPerformanceProvider {
            for id in merged.keys {
                if let performance = await observedPerformanceProvider(id) {
                    merged[id]?.performance = performance
                }
            }
        }
        registryByID = merged
        rebuildSlugIndex()
        activeModels = sortedModelsFromRegistry()
        await publishRegistryWireIfChanged()
    }

    /// Rebuilds ``slugIndex`` from the current registry. First-seen wins on collision (deterministic by UUID order).
    private func rebuildSlugIndex() {
        var index: [String: UUID] = [:]
        let orderedEntries = registryByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        for entry in orderedEntries {
            for slug in entry.allSlugs {
                if let existing = index[slug], existing != entry.id {
                    logger?.warning("Model slug collision: '\(slug)' maps to \(existing) and \(entry.id); first-seen wins.")
                    continue
                }
                index[slug] = entry.id
            }
        }
        slugIndex = index
    }

    private func publishRegistryWireIfChanged() async {
        guard let registryTopicHub else { return }
        let models = sortedModelsFromRegistry()
        let nextByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let changes = ModelRegistryDiff.compute(previous: lastPublishedRegistryByID, next: nextByID)
        let snapshot = ModelsRegistryPayload(models: models)
        await registryTopicHub.cacheRegistrySnapshot(snapshot)
        guard !changes.isEmpty else { return }
        lastPublishedRegistryByID = nextByID
        await registryTopicHub.broadcastModelsRegistryEvent(
            ModelsRegistryEventPayload(changes: changes)
        )
    }

    private func sortedModelsFromRegistry() -> [Model] {
        registryByID.values
            .sorted { ($0.displayName ?? $0.id.uuidString) < ($1.displayName ?? $1.id.uuidString) }
            .map { $0.toModel() }
    }

    func getAvailableOllamaModels() async -> [Model] {
        await syncRegistryFromDiscovery()
        return registryByID.values
            .filter { $0.primaryBinding?.providerId == "ollama" }
            .sorted { ($0.displayName ?? $0.id.uuidString) < ($1.displayName ?? $1.id.uuidString) }
            .map { $0.toModel() }
    }

    func getAvailableLMStudioModels() async -> [Model] {
        await syncRegistryFromDiscovery()
        return registryByID.values
            .filter { $0.primaryBinding?.providerId == "lmstudio" }
            .sorted { ($0.displayName ?? $0.id.uuidString) < ($1.displayName ?? $1.id.uuidString) }
            .map { $0.toModel() }
    }

    private func discoverOllamaEntries() async -> [ModelRegistryEntry] {
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
            guard let modelConfig = Constants.ollamaModelIDMap[model.name] else {
                logger?.warning("The Ollama model \(model.name) was not found in the predefined list. Ignoring.")
                continue
            }
            let binding = ProviderBinding(
                providerId: "ollama",
                modelProtocol: modelConfig.modelProtocol,
                endpointModelId: model.name,
                serverURL: Constants.ollamaServerURL,
                priority: 0,
                authProfile: nil
            )
            do {
                let detail = try await fetchOllamaModelDetail(modelName: model.name, config: modelConfig)
                let entry = ModelRegistryEntry(
                    id: modelConfig.uuid,
                    family: nil,
                    displayName: model.name,
                    capabilities: detail.capabilities,
                    requestFeatures: Self.mergedRequestFeaturesFromConfig(modelConfig),
                    maxContextLength: detail.maxContextLength,
                    maxOutputTokens: nil,
                    providers: [binding],
                    useClasses: [],
                    cost: modelConfig.hardcodedCost,
                    routing: modelConfig.hardcodedRouting ?? Self.defaultRoutingMetadata(for: modelConfig.modelProtocol)
                )
                entries.append(entry)
            } catch {
                logger?.warning("Ollama: modelInfo failed for \(model.name); skipping that model: \(error)")
                continue
            }
        }
        return entries
    }

    private func fetchOllamaModelDetail(modelName: String, config: ModelConfig) async throws -> (capabilities: Set<LLMCapability>, maxContextLength: Int?) {
        let ollama = OllamaKit(baseURL: Constants.ollamaServerURL)
        let data = OKModelInfoRequestData(name: modelName)
        let response = try await ollama.modelInfo(data: data)
        var caps = Set<LLMCapability>()
        for capability in response.capabilities {
            switch capability {
            case .completion:
                caps.insert(.completion)
            case .tools:
                caps.insert(.tools)
            case .insert:
                caps.insert(.insert)
            case .vision:
                caps.insert(.vision)
            case .embedding:
                caps.insert(.embedding)
            case .thinking:
                caps.insert(.thinking)
            case .image:
                caps.insert(.imageGeneration)
            case .audio:
                caps.insert(.audio)
            }
        }
        for hardcodedCapability in config.hardcodedCapabilities {
            caps.insert(hardcodedCapability)
        }
        Self.normalizeReasoningCapabilities(&caps)
        let maxContextLength = Self.contextLength(from: response)
        return (caps, maxContextLength)
    }

    private func discoverLMStudioEntries() async -> [ModelRegistryEntry] {
        let apiManager = RestAPIManager(baseURL: Constants.lmStudioServerURL, sseTimeoutInterval: 31536000.0, logger: logger)
        let response: LMStudioGetModelsResponse
        do {
            response = try await apiManager.decodableRequest("api/v0/models")
        } catch {
            logger?.warning("LM Studio: failed to decode GET api/v0/models (is the local server running on \(Constants.lmStudioServerURL.absoluteString)?): \(error)")
            return []
        }
        var entries: [ModelRegistryEntry] = []
        for model in response.data {
            guard let modelConfig = Constants.lmStudioModelIDMap[model.id] else {
                logger?.warning("The LMStudio model \(model.id) was not found in the predefined list. Ignoring.")
                continue
            }
            var capabilities = lmStudioCapabilities(for: model, modelConfig: modelConfig)
            Self.normalizeReasoningCapabilities(&capabilities)
            let binding = ProviderBinding(
                providerId: "lmstudio",
                modelProtocol: modelConfig.modelProtocol,
                endpointModelId: model.id,
                serverURL: Constants.lmStudioServerURL,
                priority: 0,
                authProfile: nil
            )
            let entry = ModelRegistryEntry(
                id: modelConfig.uuid,
                family: nil,
                displayName: model.id,
                capabilities: capabilities,
                requestFeatures: Self.mergedRequestFeaturesFromConfig(modelConfig),
                maxContextLength: model.max_context_length,
                maxOutputTokens: nil,
                providers: [binding],
                useClasses: [],
                cost: modelConfig.hardcodedCost,
                routing: modelConfig.hardcodedRouting ?? Self.defaultRoutingMetadata(for: modelConfig.modelProtocol)
            )
            entries.append(entry)
        }
        return entries
    }

    private func lmStudioCapabilities(for model: LMStudioGetModelsResponseData, modelConfig: ModelConfig) -> Set<LLMCapability> {
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

    /// Extracts max context length from Ollama model info (model_info family context_length or parameters num_ctx).
    static func contextLength(from response: OKModelInfoResponse) -> Int? {
        let family = response.details.family
        if let ctx: Int = response.modelInfo.getProperty(family: family, property: "context_length") {
            return ctx
        }
        if let ctx: Int = response.modelInfo.getProperty(family: family, property: "contextLength") {
            return ctx
        }
        for fam in response.modelInfo.getAvailableFamilies() {
            if let ctx: Int = response.modelInfo.getProperty(family: fam, property: "context_length") {
                return ctx
            }
            if let ctx: Int = response.modelInfo.getProperty(family: fam, property: "contextLength") {
                return ctx
            }
        }
        return parseNumCtx(from: response.parameters)
    }

    /// Parses num_ctx from Ollama parameters string (e.g. "temperature 0.7\nnum_ctx 2048").
    static func parseNumCtx(from parameters: String) -> Int? {
        for line in parameters.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("num_ctx "), let value = Int(line.dropFirst("num_ctx ".count).trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    public func addModels(_ models: [Model]) async throws {
        for model in models {
            if registryByID[model.id] == nil {
                registryByID[model.id] = ModelRegistryEntry.from(model: model)
            }
        }
        rebuildSlugIndex()
        activeModels = sortedModelsFromRegistry()
        await publishRegistryWireIfChanged()
    }

    // MARK: - Request features merge (protocol baseline + Constants overlay)

    static func requestFeaturesBaseline(for modelProtocol: ModelProtocol) -> ModelRequestFeatures {
        switch modelProtocol {
        case .ollama:
            return ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject],
                parallelToolCalls: .unsupported,
                reasoningEfforts: [],
                toolChoiceModes: [.auto]
            )
        case .openAIAPI:
            return ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject, .jsonSchema],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .none, .required, .specific]
            )
        case .lmStudio:
            return ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject, .jsonSchema],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .required]
            )
        case .anthropic:
            return ModelRequestFeatures(
                streaming: true,
                responseFormats: [.text, .jsonObject],
                parallelToolCalls: .uncapped,
                reasoningEfforts: [],
                toolChoiceModes: [.auto, .required, .specific]
            )
        }
    }

    private static func mergedRequestFeaturesFromConfig(_ config: ModelConfig) -> ModelRequestFeatures {
        mergeRequestFeatures(
            baseline: requestFeaturesBaseline(for: config.modelProtocol),
            overlay: config.hardcodedRequestFeatures
        )
    }

    static func mergeRequestFeatures(
        baseline: ModelRequestFeatures,
        overlay: ModelRequestFeatures?
    ) -> ModelRequestFeatures {
        guard let overlay else { return baseline }
        return ModelRequestFeatures(
            streaming: baseline.streaming || overlay.streaming,
            responseFormats: baseline.responseFormats.union(overlay.responseFormats),
            parallelToolCalls: mergeParallelToolSupport(baseline.parallelToolCalls, overlay.parallelToolCalls),
            reasoningEfforts: baseline.reasoningEfforts.union(overlay.reasoningEfforts),
            toolChoiceModes: baseline.toolChoiceModes.union(overlay.toolChoiceModes)
        )
    }

    private static func mergeParallelToolSupport(
        _ a: ParallelToolCallSupport,
        _ b: ParallelToolCallSupport
    ) -> ParallelToolCallSupport {
        switch (a, b) {
        case (.uncapped, _), (_, .uncapped):
            return .uncapped
        case (.capped(let x), .capped(let y)):
            return .capped(max(x, y))
        case (.capped(let x), .unsupported), (.unsupported, .capped(let x)):
            return .capped(x)
        default:
            return .unsupported
        }
    }

    /// If both `.thinking` and `.reasoningRequired` appear, keep required-only semantics.
    private static func normalizeReasoningCapabilities(_ caps: inout Set<LLMCapability>) {
        if caps.contains(.reasoningRequired) {
            caps.remove(.thinking)
        }
    }

    /// Static registry metadata hints for per-model routing windows.
    private static func defaultRoutingMetadata(for modelProtocol: ModelProtocol) -> ModelRoutingMetadata {
        switch modelProtocol {
        case .ollama:
            return ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 8, tokens: 120_000, windowMs: 60_000)
            )
        case .openAIAPI:
            return ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 20, tokens: 300_000, windowMs: 60_000)
            )
        case .lmStudio:
            return ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 12, tokens: 200_000, windowMs: 60_000)
            )
        case .anthropic:
            return ModelRoutingMetadata(
                rateLimit: ModelRateLimitMetadata(requests: 20, tokens: 300_000, windowMs: 60_000)
            )
        }
    }
}
