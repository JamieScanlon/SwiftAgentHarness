import Combine
import Foundation
import Logging
import OllamaKit
import SwiftAgentKit

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
    private let providerPreference: ModelPoolProviderPreferenceConfiguration
    private let authProfileStore: AuthProfileStore

    public init(
        logger: Logger? = nil,
        registryTopicHub: (any ModelPoolResourceTopicPublishing)? = nil,
        observedPerformanceProvider: (@Sendable (UUID) async -> ModelObservedPerformance?)? = nil,
        providerPreference: ModelPoolProviderPreferenceConfiguration? = nil,
        authProfileStore: AuthProfileStore = .production()
    ) {
        self.logger = logger
        self.registryTopicHub = registryTopicHub
        self.observedPerformanceProvider = observedPerformanceProvider
        self.providerPreference = providerPreference ?? ModelPoolProviderPreferenceConfiguration.specDefaults
        self.authProfileStore = authProfileStore
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

    /// Tracks one-time dynamic model preparation per provider endpoint slug.
    private var preparedDynamicModelKeys: Set<String> = []

    /// Canonical resolve: O(1) for `.id` and `.slug` via the registry indexes; ranked candidates for `.query`.
    /// Throws ``ModelPoolError/unavailable(reference:)`` when no entry matches.
    public func resolve(_ ref: ModelReference) async throws -> ModelRegistryEntry {
        await syncRegistryFromDiscovery()
        switch ref {
        case .id(let id):
            if let entry = registryByID[id] { return entry }
        case .slug(let slug):
            if let id = slugIndex[slug], let entry = registryByID[id] { return entry }
            if let entry = try await lazyResolveSlug(slug) { return entry }
        case .query(let query):
            let entries = Array(registryByID.values)
            if let hit = ModelQuery.rank(entries: entries, query: query).first { return hit }
        }
        throw ModelPoolError.unavailable(reference: ref)
    }

    private func lazyResolveSlug(_ slug: String) async throws -> ModelRegistryEntry? {
        guard slug.contains("/") else { return nil }
        let modelRef: ModelRef
        do {
            modelRef = try ModelRefParser.parse(slug)
        } catch {
            return nil
        }
        ProviderRegistry.ensureBootstrapped()
        guard let manifest = ProviderRegistry.optionalManifest(for: modelRef.providerID),
              ProviderLifecycle.lifecycleState(for: manifest, authStore: authProfileStore) == .registered,
              let provider = ProviderRegistry.textInferenceProvider(for: modelRef.providerID),
              let endpoint = manifest.defaultEndpoint
        else {
            return nil
        }
        let binding = ProviderBinding(
            providerId: modelRef.providerID,
            modelProtocol: provider.modelProtocol,
            endpointModelId: modelRef.modelID,
            serverURL: endpoint.baseURL
        )
        guard var catalogEntry = await provider.resolveDynamicModel(
            ProviderDynamicModelContext(
                endpointModelId: modelRef.modelID,
                serverURL: endpoint.baseURL
            )
        ) else {
            return nil
        }
        let prepareKey = "\(modelRef.providerID)#\(modelRef.modelID)#\(endpoint.baseURL.absoluteString)"
        if !preparedDynamicModelKeys.contains(prepareKey) {
            catalogEntry = await ProviderRuntimeHooks.prepareDynamicModel(
                binding: binding,
                catalogEntry: catalogEntry
            )
            preparedDynamicModelKeys.insert(prepareKey)
        }
        var entry = catalogEntry.toRegistryEntry(
            providerID: modelRef.providerID,
            serverURL: endpoint.baseURL
        )
        if !ProviderRuntimeHooks.preferRuntimeResolvedModel(binding: binding),
           let staticEntry = provider.staticCatalogEntries().first(where: { $0.endpointModelId == modelRef.modelID }) {
            let staticRegistry = staticEntry.toRegistryEntry(
                providerID: modelRef.providerID,
                serverURL: endpoint.baseURL
            )
            if entry.maxContextLength == nil {
                entry.maxContextLength = staticRegistry.maxContextLength
            }
            if entry.compat == nil {
                entry.compat = staticRegistry.compat
            }
            if entry.cost == nil {
                entry.cost = staticRegistry.cost
            }
        }
        registryByID[entry.id] = entry
        await applyRegistryMerge()
        return registryByID.values.first(where: { $0.allSlugs.contains(slug) || $0.allSlugs.contains(modelRef.canonicalString) })
            ?? registryByID[entry.id]
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
        ProviderRegistry.ensureBootstrapped()
        var discovered: [ModelRegistryEntry] = []
        for provider in ProviderRegistry.registeredTextInferenceProviders(authStore: authProfileStore) {
            for entry in await provider.discoverEntries(logger: logger) {
                discovered.append(entry)
            }
        }
        registryByID = mergeDiscoveredEntries(discovered)
        if let observedPerformanceProvider {
            for id in registryByID.keys {
                if let performance = await observedPerformanceProvider(id) {
                    registryByID[id]?.performance = performance
                }
            }
        }
        rebuildSlugIndex()
        activeModels = sortedModelsFromRegistry()
        await publishRegistryWireIfChanged()
    }

    private func mergeDiscoveredEntries(_ entries: [ModelRegistryEntry]) -> [UUID: ModelRegistryEntry] {
        LogicalModelRegistryMerger.merge(
            entries: entries,
            providerPreference: providerPreference,
            logger: logger
        )
    }

    private func applyRegistryMerge() async {
        registryByID = mergeDiscoveredEntries(Array(registryByID.values))
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


    /// Extracts max context length from Ollama model info (model_info family context_length or parameters num_ctx).
    public static func contextLength(from response: OKModelInfoResponse) -> Int? {
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
        var entries = Array(registryByID.values)
        for model in models where registryByID[model.id] == nil {
            entries.append(ModelRegistryEntry.from(model: model))
        }
        registryByID = mergeDiscoveredEntries(entries)
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

    static func mergedRequestFeaturesFromConfig(_ config: ModelConfig) -> ModelRequestFeatures {
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

    /// Applies a per-binding downward override to the model entry's tool-choice ladder.
    static func effectiveToolChoiceModes(
        baseline: Set<ToolChoiceMode>,
        override: Set<ToolChoiceMode>?
    ) -> Set<ToolChoiceMode> {
        guard let override else { return baseline }
        return baseline.intersection(override).union([.auto])
    }

    static func requestFeatures(
        for model: Model,
        binding: ProviderBinding
    ) -> ModelRequestFeatures {
        guard binding.toolChoiceModesOverride != nil else {
            return model.requestFeatures
        }
        var features = model.requestFeatures
        features.toolChoiceModes = effectiveToolChoiceModes(
            baseline: model.requestFeatures.toolChoiceModes,
            override: binding.toolChoiceModesOverride
        )
        return features
    }

    static func model(
        _ model: Model,
        applyingBinding binding: ProviderBinding
    ) -> Model {
        guard binding.toolChoiceModesOverride != nil else { return model }
        var adjusted = model
        adjusted.requestFeatures = requestFeatures(for: model, binding: binding)
        return adjusted
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
    public static func normalizeReasoningCapabilities(_ caps: inout Set<LLMCapability>) {
        if caps.contains(.reasoningRequired) {
            caps.remove(.thinking)
        }
    }

    /// Static registry metadata hints for per-model routing windows.
    static func defaultRoutingMetadata(for modelProtocol: ModelProtocol) -> ModelRoutingMetadata {
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
