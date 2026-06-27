import Foundation

enum ProviderManifestLoader {
    static func bundledManifestData(for providerID: ProviderID) -> Data? {
        let candidates = [
            Bundle.module.url(forResource: providerID, withExtension: "manifest.json", subdirectory: "manifests"),
            Bundle.module.url(forResource: providerID, withExtension: "manifest.json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return nil }
        return try? Data(contentsOf: url)
    }

    static func decodeBundledManifest(for providerID: ProviderID) throws -> ProviderManifest? {
        guard let data = bundledManifestData(for: providerID) else { return nil }
        return try JSONDecoder().decode(ProviderManifest.self, from: data)
    }
}
