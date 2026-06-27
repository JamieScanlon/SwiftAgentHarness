import Foundation
import SwiftAgentKit

/// How to reach one logical model on a concrete backend (spec: `ProviderBinding`, Swift-shaped).
public struct ProviderBinding: Sendable, Hashable, Codable {
    public var providerId: String
    public var modelProtocol: ModelProtocol
    public var endpointModelId: String
    public var serverURL: URL
    /// Lower sorts first when failing over.
    public var priority: Int
    public var authProfile: String?
    /// Downward-only override of the model entry's ``ModelRequestFeatures/toolChoiceModes``.
    public var toolChoiceModesOverride: Set<ToolChoiceMode>?

    public init(
        providerId: String,
        modelProtocol: ModelProtocol,
        endpointModelId: String,
        serverURL: URL,
        priority: Int = 0,
        authProfile: String? = nil,
        toolChoiceModesOverride: Set<ToolChoiceMode>? = nil
    ) {
        self.providerId = providerId
        self.modelProtocol = modelProtocol
        self.endpointModelId = endpointModelId
        self.serverURL = serverURL
        self.priority = priority
        self.authProfile = authProfile
        self.toolChoiceModesOverride = toolChoiceModesOverride
    }
}

/// Registry row for the model pool (spec: `ModelEntry`; capabilities stay ``Set<LLMCapability>``).
public struct ModelRegistryEntry: Sendable, Hashable {
    public var id: UUID
    public var family: String?
    public var displayName: String?
    public var capabilities: Set<LLMCapability>
    /// Per-call request knobs this entry honors (merged from protocol baseline, hardcoded config, and discovery).
    public var requestFeatures: ModelRequestFeatures
    public var maxContextLength: Int?
    public var maxOutputTokens: Int?
    public var providers: [ProviderBinding]
    public var useClasses: [String]
    /// Optional pricing scaffold (spec: `ModelEntry.cost`).
    public var cost: ModelCostBudget?
    /// Rolling observed runtime performance for ranking.
    public var performance: ModelObservedPerformance?
    /// Optional routing metadata (`ModelEntry.routing`).
    public var routing: ModelRoutingMetadata?
    /// Provider-specific declarative quirks (spec: catalog `compat` block).
    public var compat: ProviderModelCompat?

    public init(
        id: UUID,
        family: String? = nil,
        displayName: String? = nil,
        capabilities: Set<LLMCapability>,
        requestFeatures: ModelRequestFeatures = .unknown,
        maxContextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        providers: [ProviderBinding],
        useClasses: [String] = [],
        cost: ModelCostBudget? = nil,
        performance: ModelObservedPerformance? = nil,
        routing: ModelRoutingMetadata? = nil,
        compat: ProviderModelCompat? = nil
    ) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.capabilities = capabilities
        self.requestFeatures = requestFeatures
        self.maxContextLength = maxContextLength
        self.maxOutputTokens = maxOutputTokens
        self.providers = providers.sorted { $0.priority < $1.priority }
        self.useClasses = useClasses
        self.cost = cost
        self.performance = performance
        self.routing = routing
        self.compat = compat
    }

    /// Primary wire target for the shared ``Model`` DTO (lowest `priority` wins).
    public var primaryBinding: ProviderBinding? {
        providers.first
    }

    /// Authoritative slug for this entry — primary binding's ``ProviderBinding/endpointModelId``,
    /// falling back to ``displayName`` and finally the UUID string. Used by ``ModelReference/slug(_:)``.
    public var slug: String {
        if let primary = primaryBinding { return primary.endpointModelId }
        if let displayName { return displayName }
        return id.uuidString
    }

    /// Every binding's ``ProviderBinding/endpointModelId`` (deduped, primary first) — lets the slug index
    /// resolve callers who address a non-primary binding.
    public var allSlugs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for binding in providers where seen.insert(binding.endpointModelId).inserted {
            ordered.append(binding.endpointModelId)
        }
        return ordered
    }

    public func toModel() -> Model {
        guard let primary = primaryBinding else {
            preconditionFailure("ModelRegistryEntry requires at least one ProviderBinding")
        }
        let caps = Self.stableCapabilityArray(capabilities)
        return Model(
            id: id,
            protocol: primary.modelProtocol,
            modelName: primary.endpointModelId,
            serverURL: primary.serverURL,
            capabilities: caps,
            modelProtocol: primary.modelProtocol,
            maxContextLength: maxContextLength,
            requestFeatures: requestFeatures,
            cost: cost,
            performance: performance,
            routing: routing
        )
    }

    /// Builds a minimal registry row from an existing ``Model`` (e.g. cache hydration).
    public static func from(model: Model, cost: ModelCostBudget? = nil) -> ModelRegistryEntry {
        let binding = ProviderBinding(
            providerId: model.modelProtocol.rawValue,
            modelProtocol: model.modelProtocol,
            endpointModelId: model.modelName,
            serverURL: model.serverURL,
            priority: 0,
            authProfile: nil
        )
        return ModelRegistryEntry(
            id: model.id,
            family: nil,
            displayName: model.modelName,
            capabilities: Set(model.capabilities),
            requestFeatures: model.requestFeatures,
            maxContextLength: model.maxContextLength,
            maxOutputTokens: nil,
            providers: [binding],
            useClasses: [],
            cost: cost ?? model.cost,
            performance: model.performance,
            routing: model.routing
        )
    }

    static func stableCapabilityArray(_ set: Set<LLMCapability>) -> [LLMCapability] {
        set.sorted { $0.rawValue < $1.rawValue }
    }
}
