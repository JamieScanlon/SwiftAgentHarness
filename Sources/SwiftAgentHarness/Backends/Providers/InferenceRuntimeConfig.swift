import Foundation

/// Open string-backed kind — matches `ProviderAdapterFactory.adapterKind` / JSON plugins.
/// Not a closed enum: hosts and third parties can register new factories without a library change.
public struct ProviderAdapterKind: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let ollama = Self(rawValue: "ollama")
    public static let lmStudio = Self(rawValue: "lmstudio")
    public static let openAICompat = Self(rawValue: "openai-compat")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let openRouter = Self(rawValue: "openrouter")
}

/// Host-supplied configuration for an API-server inference provider instance.
///
/// `serverURL` may be localhost or any reachable remote host. `providerID` is host-chosen
/// and need not match `adapterKind` (the wire/discovery protocol).
public struct InferenceRuntimeConfig: Sendable {
    /// Registry id for this provider instance (host-chosen; need not match adapterKind).
    public var providerID: ProviderID
    public var label: String
    /// Selects the wire/discovery implementation via `ProviderAdapterFactoryRegistry`.
    public var adapterKind: ProviderAdapterKind
    public var serverURL: URL
    /// Allowlist + capability/cost/request-feature overlays for discovered models.
    public var modelIDMap: [String: ModelConfig]

    public init(
        providerID: ProviderID,
        label: String,
        adapterKind: ProviderAdapterKind,
        serverURL: URL,
        modelIDMap: [String: ModelConfig] = [:]
    ) {
        self.providerID = providerID
        self.label = label
        self.adapterKind = adapterKind
        self.serverURL = serverURL
        self.modelIDMap = modelIDMap
    }
}

/// Local catalog pricing baselines used by Model Pool ranking/budget projection for
/// self-hosted or API-server runtimes. These are internal routing heuristics (not upstream billing rates).
public enum ModelCatalogCostPresets: Sendable {
    public static let `default` = ModelCostBudget(
        inputPer1MUSD: 0.10,
        outputPer1MUSD: 0.30,
        cachedInputPer1MUSD: 0.02
    )
    public static let budget = ModelCostBudget(
        inputPer1MUSD: 0.04,
        outputPer1MUSD: 0.12,
        cachedInputPer1MUSD: 0.01
    )
    public static let premium = ModelCostBudget(
        inputPer1MUSD: 0.80,
        outputPer1MUSD: 1.60,
        cachedInputPer1MUSD: 0.10
    )
}
