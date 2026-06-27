import Foundation

/// Canonical two-part model reference: `provider/model-id`.
public struct ModelRef: Sendable, Equatable, Hashable {
    public var providerID: ProviderID
    public var modelID: String

    public init(providerID: ProviderID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public var canonicalString: String {
        "\(providerID)/\(modelID)"
    }
}

public enum ModelRefParseError: Error, Equatable, Sendable {
    case emptyInput
    case emptyProvider
    case emptyModelID
    case unknownProvider(String)
}

/// Single parse site for `provider/model-id` addressing (spec: model-ref naming).
public enum ModelRefParser {
    public static func normalizeProviderID(_ raw: String) -> ProviderID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let resolved = ProviderManifests.providerID(forAlias: trimmed) {
            return resolved
        }
        return trimmed
    }

    public static func parse(
        _ input: String,
        defaultProvider: ProviderID? = nil,
        normalizeModelID: @Sendable (ProviderID, String) -> String = { _, modelID in modelID }
    ) throws -> ModelRef {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelRefParseError.emptyInput }

        let providerID: ProviderID
        let modelID: String

        if let slashIndex = trimmed.firstIndex(of: "/") {
            let providerRaw = String(trimmed[..<slashIndex])
            let modelRaw = String(trimmed[trimmed.index(after: slashIndex)...])
            providerID = normalizeProviderID(providerRaw)
            guard !providerID.isEmpty else { throw ModelRefParseError.emptyProvider }
            modelID = normalizeModelID(providerID, modelRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            guard let defaultProvider else {
                if let inferred = inferProvider(fromBareModelID: trimmed) {
                    providerID = inferred
                } else {
                    throw ModelRefParseError.unknownProvider(trimmed)
                }
                modelID = normalizeModelID(providerID, trimmed)
                return ModelRef(providerID: providerID, modelID: modelID)
            }
            providerID = normalizeProviderID(defaultProvider)
            modelID = normalizeModelID(providerID, trimmed)
        }

        guard !modelID.isEmpty else { throw ModelRefParseError.emptyModelID }
        return ModelRef(providerID: providerID, modelID: modelID)
    }

    /// Infer provider from bare model id via registered manifest prefix patterns.
    public static func inferProvider(fromBareModelID modelID: String) -> ProviderID? {
        let lower = modelID.lowercased()
        for manifest in ProviderManifests.all {
            for prefix in manifest.modelSupport.modelPrefixes {
                if lower.hasPrefix(prefix.lowercased()) {
                    return manifest.id
                }
            }
        }
        return nil
    }
}
