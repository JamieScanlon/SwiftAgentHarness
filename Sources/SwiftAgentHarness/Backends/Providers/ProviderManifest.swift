import Foundation

public typealias ProviderID = String

public struct ProviderEndpoint: Sendable, Equatable, Codable, Hashable {
    public var id: String
    public var baseURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case baseURL = "baseUrl"
    }

    public init(id: String, baseURL: URL) {
        self.id = id
        self.baseURL = baseURL
    }
}

public struct ProviderAuthChoice: Sendable, Equatable, Codable, Hashable {
    public var id: String
    public var label: String
    public var envVars: [String]
    public var cliFlag: String?
    public var cliOption: String?
    public var onboardingScopes: [String]
    public var authType: AuthProfileType?

    public init(
        id: String,
        label: String,
        envVars: [String],
        cliFlag: String? = nil,
        cliOption: String? = nil,
        onboardingScopes: [String] = [],
        authType: AuthProfileType? = nil
    ) {
        self.id = id
        self.label = label
        self.envVars = envVars
        self.cliFlag = cliFlag
        self.cliOption = cliOption
        self.onboardingScopes = onboardingScopes
        self.authType = authType
    }
}

public struct ProviderModelSupport: Sendable, Equatable, Codable, Hashable {
    public var modelPrefixes: [String]

    public init(modelPrefixes: [String]) {
        self.modelPrefixes = modelPrefixes
    }
}

public struct ProviderCLIBackend: Sendable, Equatable, Codable, Hashable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ProviderUIHints: Sendable, Equatable, Codable, Hashable {
    public var iconRef: String?
    public var category: String?

    public init(iconRef: String? = nil, category: String? = nil) {
        self.iconRef = iconRef
        self.category = category
    }
}

/// Static, schema-validated provider metadata (spec: plugin manifest).
public struct ProviderManifest: Sendable, Equatable, Codable, Hashable {
    public var id: ProviderID
    public var label: String
    public var providerEndpoints: [ProviderEndpoint]
    public var providerAuthAliases: [String]
    public var providerAuthChoices: [ProviderAuthChoice]
    public var modelSupport: ProviderModelSupport
    public var cliBackends: [ProviderCLIBackend]
    public var uiHints: ProviderUIHints?
    /// Capability slots this plugin participates in.
    public var capabilitySlots: [ProviderCapabilitySlot]

    public init(
        id: ProviderID,
        label: String,
        providerEndpoints: [ProviderEndpoint],
        providerAuthAliases: [String] = [],
        providerAuthChoices: [ProviderAuthChoice],
        modelSupport: ProviderModelSupport,
        cliBackends: [ProviderCLIBackend] = [],
        uiHints: ProviderUIHints? = nil,
        capabilitySlots: [ProviderCapabilitySlot] = [.textInference]
    ) {
        self.id = id
        self.label = label
        self.providerEndpoints = providerEndpoints
        self.providerAuthAliases = providerAuthAliases
        self.providerAuthChoices = providerAuthChoices
        self.modelSupport = modelSupport
        self.cliBackends = cliBackends
        self.uiHints = uiHints
        self.capabilitySlots = capabilitySlots
    }

    public var defaultEndpoint: ProviderEndpoint? {
        providerEndpoints.first
    }
}

public enum ProviderManifests {
    public static let openai = ProviderManifest(
        id: "openai",
        label: "OpenAI",
        providerEndpoints: [
            ProviderEndpoint(id: "openai-default", baseURL: URL(string: "https://api.openai.com/v1")!),
        ],
        providerAuthAliases: ["openai", "gpt"],
        providerAuthChoices: [
            ProviderAuthChoice(
                id: "api-key",
                label: "API Key",
                envVars: ["SAH_OPENAI_API_KEY", "OPENAI_API_KEY"],
                cliFlag: "--openai-key",
                cliOption: "openaiKey",
                authType: .apiKey
            ),
        ],
        modelSupport: ProviderModelSupport(modelPrefixes: ["gpt-", "o1-", "o3-", "o4-"]),
        cliBackends: [
            ProviderCLIBackend(id: "openai-codex", label: "Codex CLI"),
        ],
        uiHints: ProviderUIHints(iconRef: "openai-mark", category: "frontier"),
        capabilitySlots: [.textInference, .cliInferenceBackend, .speech, .imageGeneration, .realtimeVoice]
    )

    public static let anthropic = ProviderManifest(
        id: "anthropic",
        label: "Anthropic",
        providerEndpoints: [
            ProviderEndpoint(id: "anthropic-default", baseURL: URL(string: "https://api.anthropic.com")!),
        ],
        providerAuthAliases: ["anthropic", "claude"],
        providerAuthChoices: [
            ProviderAuthChoice(
                id: "api-key",
                label: "API Key",
                envVars: ["SAH_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"],
                cliFlag: "--anthropic-key",
                cliOption: "anthropicKey",
                authType: .apiKey
            ),
        ],
        modelSupport: ProviderModelSupport(modelPrefixes: ["claude-"]),
        uiHints: ProviderUIHints(iconRef: "anthropic-mark", category: "frontier"),
        capabilitySlots: [.textInference, .mediaUnderstanding]
    )

    public static let ollama = ProviderManifest(
        id: "ollama",
        label: "Ollama",
        providerEndpoints: [
            ProviderEndpoint(id: "ollama-default", baseURL: Constants.ollamaServerURL),
        ],
        providerAuthAliases: ["ollama"],
        providerAuthChoices: [],
        modelSupport: ProviderModelSupport(modelPrefixes: []),
        uiHints: ProviderUIHints(iconRef: "ollama-mark", category: "local"),
        capabilitySlots: [.textInference]
    )

    public static let lmstudio = ProviderManifest(
        id: "lmstudio",
        label: "LM Studio",
        providerEndpoints: [
            ProviderEndpoint(id: "lmstudio-default", baseURL: Constants.lmStudioServerURL),
        ],
        providerAuthAliases: ["lmstudio", "lm-studio"],
        providerAuthChoices: [],
        modelSupport: ProviderModelSupport(modelPrefixes: []),
        uiHints: ProviderUIHints(iconRef: "lmstudio-mark", category: "local"),
        capabilitySlots: [.textInference]
    )

    public static let openrouter = ProviderManifest(
        id: "openrouter",
        label: "OpenRouter",
        providerEndpoints: [
            ProviderEndpoint(id: "openrouter-default", baseURL: URL(string: "https://openrouter.ai/api/v1")!),
        ],
        providerAuthAliases: ["openrouter"],
        providerAuthChoices: [
            ProviderAuthChoice(
                id: "api-key",
                label: "API Key",
                envVars: ["SAH_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"],
                authType: .apiKey
            ),
        ],
        modelSupport: ProviderModelSupport(modelPrefixes: []),
        uiHints: ProviderUIHints(iconRef: "openrouter-mark", category: "aggregator"),
        capabilitySlots: [.textInference]
    )

    public static let all: [ProviderManifest] = [openai, anthropic, ollama, lmstudio, openrouter]

    public static func manifest(for providerID: ProviderID) -> ProviderManifest? {
        all.first { $0.id == providerID }
    }

    public static func manifest(forAlias alias: String) -> ProviderManifest? {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { manifest in
            manifest.id == normalized || manifest.providerAuthAliases.contains(normalized)
        }
    }

    public static func providerID(forAlias alias: String) -> ProviderID? {
        manifest(forAlias: alias)?.id
    }
}
