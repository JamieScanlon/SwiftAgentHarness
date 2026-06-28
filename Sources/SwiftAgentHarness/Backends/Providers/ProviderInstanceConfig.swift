import Foundation

public struct ProviderInstanceConfig: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var adapterKind: String
    public var id: ProviderID
    public var label: String
    public var providerEndpoints: [ProviderEndpoint]
    public var providerAuthAliases: [String]
    public var providerAuthChoices: [ProviderAuthChoice]
    public var modelSupport: ProviderModelSupport
    public var cliBackends: [ProviderCLIBackend]
    public var uiHints: ProviderUIHints?
    public var capabilitySlots: [ProviderCapabilitySlot]
    public var `default`: Bool
    public var catalog: [ProviderInstanceCatalogRow]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case adapterKind
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
        case catalog
    }

    public init(
        schemaVersion: Int = 1,
        adapterKind: String,
        id: ProviderID,
        label: String,
        providerEndpoints: [ProviderEndpoint],
        providerAuthAliases: [String] = [],
        providerAuthChoices: [ProviderAuthChoice] = [],
        modelSupport: ProviderModelSupport = ProviderModelSupport(modelPrefixes: []),
        cliBackends: [ProviderCLIBackend] = [],
        uiHints: ProviderUIHints? = nil,
        capabilitySlots: [ProviderCapabilitySlot] = [.textInference],
        default: Bool = false,
        catalog: [ProviderInstanceCatalogRow]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.adapterKind = adapterKind
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
        self.catalog = catalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        adapterKind = try container.decode(String.self, forKey: .adapterKind)
        id = try container.decode(ProviderID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        providerEndpoints = try container.decode([ProviderEndpoint].self, forKey: .providerEndpoints)
        providerAuthAliases = try container.decodeIfPresent([String].self, forKey: .providerAuthAliases) ?? []
        providerAuthChoices = try container.decodeIfPresent([ProviderAuthChoice].self, forKey: .providerAuthChoices) ?? []
        modelSupport = try container.decodeIfPresent(ProviderModelSupport.self, forKey: .modelSupport)
            ?? ProviderModelSupport(modelPrefixes: [])
        cliBackends = try container.decodeIfPresent([ProviderCLIBackend].self, forKey: .cliBackends) ?? []
        uiHints = try container.decodeIfPresent(ProviderUIHints.self, forKey: .uiHints)
        capabilitySlots = try container.decodeIfPresent([ProviderCapabilitySlot].self, forKey: .capabilitySlots) ?? [.textInference]
        `default` = try container.decodeIfPresent(Bool.self, forKey: .default) ?? false
        catalog = try container.decodeIfPresent([ProviderInstanceCatalogRow].self, forKey: .catalog)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(adapterKind, forKey: .adapterKind)
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
        try container.encodeIfPresent(catalog, forKey: .catalog)
    }

    public func mergedManifest(base: ProviderManifest) throws -> ProviderManifest {
        guard schemaVersion == 1 else {
            throw ProviderInstanceConfigError.unsupportedSchemaVersion(schemaVersion)
        }
        var manifest = ProviderManifest(
            id: id,
            label: label.isEmpty ? base.label : label,
            providerEndpoints: providerEndpoints.isEmpty ? base.providerEndpoints : providerEndpoints,
            providerAuthAliases: providerAuthAliases.isEmpty ? base.providerAuthAliases : providerAuthAliases,
            providerAuthChoices: providerAuthChoices.isEmpty ? base.providerAuthChoices : providerAuthChoices,
            modelSupport: modelSupport.modelPrefixes.isEmpty ? base.modelSupport : modelSupport,
            cliBackends: cliBackends.isEmpty ? base.cliBackends : cliBackends,
            uiHints: uiHints ?? base.uiHints,
            capabilitySlots: capabilitySlots.isEmpty ? base.capabilitySlots : capabilitySlots,
            default: `default`
        )
        try ProviderManifestValidation.validate(manifest)
        return manifest
    }

    public func toManifest() throws -> ProviderManifest {
        try mergedManifest(base: ProviderManifest(
            id: id,
            label: label,
            providerEndpoints: providerEndpoints,
            providerAuthChoices: providerAuthChoices,
            modelSupport: modelSupport,
            capabilitySlots: capabilitySlots,
            default: `default`
        ))
    }
}

public enum ProviderInstanceConfigError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unknownAdapterKind(String)
    case duplicateProviderID(ProviderID)
    case invalidFile(String)
}

public enum ConfigPluginLoader {
    public static func loadAll(from directory: URL) throws -> [ProviderID] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".providerconfig.json") }
        var loaded: [ProviderID] = []
        for url in urls {
            let id = try load(from: url)
            loaded.append(id)
        }
        return loaded
    }

    @discardableResult
    public static func load(from url: URL) throws -> ProviderID {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let config: ProviderInstanceConfig
        do {
            config = try decoder.decode(ProviderInstanceConfig.self, from: data)
        } catch {
            throw ProviderInstanceConfigError.invalidFile(url.lastPathComponent)
        }
        guard config.schemaVersion == 1 else {
            throw ProviderInstanceConfigError.unsupportedSchemaVersion(config.schemaVersion)
        }
        guard let factory = ProviderAdapterFactoryRegistry.factory(for: config.adapterKind) else {
            throw ProviderInstanceConfigError.unknownAdapterKind(config.adapterKind)
        }
        let baseManifest = try config.toManifest()
        let registration = try factory.makeRegistration(manifest: baseManifest, config: config)
        do {
            try ProviderRegistry.register(registration)
        } catch ProviderRegistryError.duplicateRegistration(let id) {
            throw ProviderInstanceConfigError.duplicateProviderID(id)
        }
        return config.id
    }
}

public struct ProviderInstanceCatalogRow: Sendable, Equatable, Codable {
    public var registryId: UUID?
    public var endpointModelId: String
    public var displayName: String?
    public var modelProtocol: String

    public func toProviderCatalogEntry(providerID: ProviderID) -> ProviderCatalogEntry {
        let protocolValue = ModelProtocol(rawValue: modelProtocol) ?? .openAIAPI
        let registryID = registryId ?? ProviderCatalogStableID.registryUUID(
            providerID: providerID,
            endpointModelId: endpointModelId
        )
        return ProviderCatalogEntry(
            registryID: registryID,
            endpointModelId: endpointModelId,
            displayName: displayName,
            modelConfig: ModelConfig(uuid: registryID, modelProtocol: protocolValue)
        )
    }
}

extension ProviderInstanceConfig {
    public func resolvedCatalogEntries() -> [ProviderCatalogEntry]? {
        catalog?.map { $0.toProviderCatalogEntry(providerID: id) }
    }
}
