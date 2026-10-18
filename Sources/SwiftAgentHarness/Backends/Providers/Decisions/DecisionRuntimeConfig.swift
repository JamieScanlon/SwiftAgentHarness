import CryptoKit
import Foundation
import SwiftAgentKit

/// One decision model a host serves through a ``DecisionRuntimeConfig``.
public struct DecisionModelConfig: Sendable {
    /// The server's own model name, always a versioned id (never a vendor alias).
    public var endpointModelID: String
    public var displayName: String?
    public var family: String?
    /// The `decide` profile; defaults to the surface's reference descriptor.
    public var profile: ContractProfile?
    public var lifecycle: ModelLifecycle
    /// Declared "same behaviour" group bounding threshold-bearing fallback.
    public var compatGroup: String?
    public var prices: PriceVector
    public var locality: ModelLocality?
    /// Roles this model is catalogued for (e.g. `gatekeeper`).
    public var roles: [String]
    public var performance: ModelObservedPerformance?

    public init(
        endpointModelID: String,
        displayName: String? = nil,
        family: String? = nil,
        profile: ContractProfile? = nil,
        lifecycle: ModelLifecycle = .active,
        compatGroup: String? = nil,
        prices: PriceVector = [],
        locality: ModelLocality? = nil,
        roles: [String] = [],
        performance: ModelObservedPerformance? = nil
    ) {
        self.endpointModelID = endpointModelID
        self.displayName = displayName
        self.family = family
        self.profile = profile
        self.lifecycle = lifecycle
        self.compatGroup = compatGroup
        self.prices = prices
        self.locality = locality
        self.roles = roles
        self.performance = performance
    }
}

/// Host-supplied configuration for a decision provider instance (SystemOne-shaped hosted decider, an edge platform,
/// a local llama.cpp / vLLM / Ollama decision server, or OpenAI Decisions).
public struct DecisionRuntimeConfig: Sendable {
    public var providerID: ProviderID
    public var label: String
    /// `.systemOne` or `.openAIDecisions`.
    public var surface: ContractSurface
    public var serverURL: URL
    /// API-key env vars. Empty means a local server that needs no credential.
    public var apiKeyEnvVars: [String]
    public var models: [DecisionModelConfig]

    public init(
        providerID: ProviderID,
        label: String,
        surface: ContractSurface = .systemOne,
        serverURL: URL,
        apiKeyEnvVars: [String] = [],
        models: [DecisionModelConfig]
    ) {
        self.providerID = providerID
        self.label = label
        self.surface = surface
        self.serverURL = serverURL
        self.apiKeyEnvVars = apiKeyEnvVars
        self.models = models
    }

    public var isLocal: Bool {
        apiKeyEnvVars.isEmpty
    }

    public func manifest() -> ProviderManifest {
        ProviderManifest(
            id: providerID,
            label: label,
            providerEndpoints: [ProviderEndpoint(id: "\(providerID)-default", baseURL: serverURL)],
            providerAuthAliases: [providerID],
            providerAuthChoices: isLocal ? [] : [
                ProviderAuthChoice(id: "api-key", label: "API Key", envVars: apiKeyEnvVars, authType: .apiKey),
            ],
            modelSupport: ProviderModelSupport(modelPrefixes: []),
            uiHints: ProviderUIHints(category: isLocal ? "local" : "decision"),
            capabilitySlots: [.decision]
        )
    }

    /// Registry rows carrying the `decide` contract. Decision bindings carry a placeholder ``ModelProtocol``; it is
    /// only consulted for `generate` dispatch, which these rows never reach.
    public func registryEntries() -> [ModelRegistryEntry] {
        models.map { model in
            let profile = model.profile ?? (surface == .openAIDecisions
                ? DecisionProfiles.openAIDecisions()
                : DecisionProfiles.systemOne())
            let binding = ProviderBinding(
                providerId: providerID,
                modelProtocol: .openAIAPI,
                endpointModelId: model.endpointModelID,
                serverURL: serverURL,
                prices: model.prices.isEmpty ? nil : model.prices
            )
            return ModelRegistryEntry(
                id: Self.stableID(providerID: providerID, endpointModelID: model.endpointModelID),
                family: model.family,
                displayName: model.displayName ?? model.endpointModelID,
                capabilities: [],
                providers: [binding],
                performance: model.performance,
                canonicalModelKey: "\(providerID)/\(model.endpointModelID)",
                contracts: [profile],
                compatGroup: model.compatGroup,
                lifecycle: model.lifecycle,
                prices: model.prices,
                locality: model.locality ?? (isLocal ? .local : .vendor),
                roles: model.roles
            )
        }
    }

    /// Deterministic UUID so registry merges and receipts stay stable across launches.
    static func stableID(providerID: ProviderID, endpointModelID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("decide:\(providerID)/\(endpointModelID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func makeProvider(
        transport: any DecisionHTTPTransport = URLSessionDecisionTransport(),
        retryExecutor: DecisionRetryExecutor = DecisionRetryExecutor(),
        authStore: AuthProfileStore = .production()
    ) -> HTTPDecisionProvider {
        let noCredential: HTTPDecisionProvider.CredentialResolver = { _ in nil }
        return HTTPDecisionProvider(
            manifest: manifest(),
            entries: registryEntries(),
            transport: transport,
            retryExecutor: retryExecutor,
            credential: isLocal ? noCredential : nil,
            authStore: authStore
        )
    }

    public func registration(
        transport: any DecisionHTTPTransport = URLSessionDecisionTransport(),
        authStore: AuthProfileStore = .production()
    ) -> ProviderRegistration {
        let provider = makeProvider(transport: transport, authStore: authStore)
        return ProviderRegistration(manifest: provider.manifest, decision: provider)
    }
}
