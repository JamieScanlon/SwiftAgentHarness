import Foundation
import SwiftAgentHarness

public enum BundledProviderManifestLoader {
    public static let bundledProviderIDs: [ProviderID] = [
        "openai", "anthropic", "ollama", "lmstudio", "openrouter",
    ]

    public static func loadManifest(for providerID: ProviderID) throws -> ProviderManifest {
        guard let manifest = try ProviderManifestLoader.decodeBundledManifest(for: providerID) else {
            throw BundledProviderManifestLoaderError.missingManifest(providerID)
        }
        try ProviderManifestValidation.validate(manifest)
        return manifest
    }

    static func loadAllManifests() throws -> [ProviderManifest] {
        try bundledProviderIDs.map { try loadManifest(for: $0) }
    }
}

enum BundledProviderManifestLoaderError: Error, Equatable, Sendable {
    case missingManifest(ProviderID)
}
