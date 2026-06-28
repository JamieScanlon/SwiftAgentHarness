import Foundation
import SwiftAgentHarness
import SwiftAgentHarnessProviders

enum ProviderTestManifestSupport {
    static let bundledProviderIDs = BundledProviderManifestLoader.bundledProviderIDs

    static func activateProviderResources() {
        ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
    }

    static func loadManifest(for providerID: ProviderID) throws -> ProviderManifest {
        activateProviderResources()
        return try BundledProviderManifestLoader.loadManifest(for: providerID)
    }

    static func loadAllManifests() throws -> [ProviderManifest] {
        try bundledProviderIDs.map { try loadManifest(for: $0) }
    }

    static func prepareRegistry() {
        activateProviderResources()
        ProviderTestSupport.registerDefaultsForTesting()
    }
}
