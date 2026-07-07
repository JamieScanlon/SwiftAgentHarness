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
    /// UI hint only: prominently offer during first-run setup. Does not affect lifecycle.
    public var `default`: Bool

    public init(
        id: ProviderID,
        label: String,
        providerEndpoints: [ProviderEndpoint],
        providerAuthAliases: [String] = [],
        providerAuthChoices: [ProviderAuthChoice],
        modelSupport: ProviderModelSupport,
        cliBackends: [ProviderCLIBackend] = [],
        uiHints: ProviderUIHints? = nil,
        capabilitySlots: [ProviderCapabilitySlot] = [.textInference],
        default: Bool = false
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
        self.default = `default`
    }

    public var defaultEndpoint: ProviderEndpoint? {
        providerEndpoints.first
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        providerEndpoints = try container.decode([ProviderEndpoint].self, forKey: .providerEndpoints)
        providerAuthAliases = try container.decodeIfPresent([String].self, forKey: .providerAuthAliases) ?? []
        providerAuthChoices = try container.decodeIfPresent([ProviderAuthChoice].self, forKey: .providerAuthChoices) ?? []
        modelSupport = try container.decode(ProviderModelSupport.self, forKey: .modelSupport)
        cliBackends = try container.decodeIfPresent([ProviderCLIBackend].self, forKey: .cliBackends) ?? []
        uiHints = try container.decodeIfPresent(ProviderUIHints.self, forKey: .uiHints)
        capabilitySlots = try container.decodeIfPresent([ProviderCapabilitySlot].self, forKey: .capabilitySlots) ?? [.textInference]
        `default` = try container.decodeIfPresent(Bool.self, forKey: .default) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case providerEndpoints
        case providerAuthAliases
        case providerAuthChoices
        case modelSupport
        case cliBackends
        case uiHints
        case capabilitySlots
        case `default`
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(providerEndpoints, forKey: .providerEndpoints)
        try container.encode(providerAuthAliases, forKey: .providerAuthAliases)
        try container.encode(providerAuthChoices, forKey: .providerAuthChoices)
        try container.encode(modelSupport, forKey: .modelSupport)
        try container.encode(cliBackends, forKey: .cliBackends)
        try container.encodeIfPresent(uiHints, forKey: .uiHints)
        try container.encode(capabilitySlots, forKey: .capabilitySlots)
        if `default` {
            try container.encode(`default`, forKey: .default)
        }
    }
}
