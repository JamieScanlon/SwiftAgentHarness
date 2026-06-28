import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("ProviderManifest decode")
struct ProviderManifestDecodeTests {
    @Test("Bundled JSON manifests decode and validate")
    func bundledManifestsDecode() throws {
        ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
        for providerID in BundledProviderManifestLoader.bundledProviderIDs {
            let manifest = try BundledProviderManifestLoader.loadManifest(for: providerID)
            #expect(manifest.id == providerID)
            #expect(!manifest.label.isEmpty)
            #expect(!manifest.providerEndpoints.isEmpty)
        }
    }

    @Test("Bundled JSON manifests are stable across decode round-trip")
    func bundledManifestRoundTrip() throws {
        ProviderResourceBundle.setResourceBundle(SwiftAgentHarnessProvidersResources.bundle)
        for providerID in BundledProviderManifestLoader.bundledProviderIDs {
            let manifest = try BundledProviderManifestLoader.loadManifest(for: providerID)
            guard let data = ProviderManifestLoader.bundledManifestData(for: providerID) else {
                Issue.record("Missing bundled manifest for \(providerID)")
                continue
            }
            let decoded = try JSONDecoder().decode(ProviderManifest.self, from: data)
            let normalizedA = ProviderManifestParity.normalize(manifest)
            let normalizedB = ProviderManifestParity.normalize(decoded)
            #expect(
                normalizedA == normalizedB,
                "Bundled manifest drift for \(providerID): update manifests/\(providerID).manifest.json"
            )
        }
    }

    @Test("Built-in catalog passes validation")
    func builtInCatalogValidates() throws {
        ProviderResourceBundle.setResourceBundle(.module)
        try ProviderManifestValidation.validateAll(try ProviderTestManifestSupport.loadAllManifests())
    }

    @Test("Prefix collision is rejected")
    func prefixCollisionRejected() {
        let a = ProviderManifest(
            id: "a",
            label: "A",
            providerEndpoints: [ProviderEndpoint(id: "a-default", baseURL: URL(string: "https://a.example/v1")!)],
            providerAuthChoices: [],
            modelSupport: ProviderModelSupport(modelPrefixes: ["gpt-"])
        )
        let b = ProviderManifest(
            id: "b",
            label: "B",
            providerEndpoints: [ProviderEndpoint(id: "b-default", baseURL: URL(string: "https://b.example/v1")!)],
            providerAuthChoices: [],
            modelSupport: ProviderModelSupport(modelPrefixes: ["gpt-"])
        )
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderManifestValidation.validateAll([a, b])
        }
    }

    @Test("Missing endpoints is rejected")
    func missingEndpointsRejected() {
        let manifest = ProviderManifest(
            id: "empty",
            label: "Empty",
            providerEndpoints: [],
            providerAuthChoices: [],
            modelSupport: ProviderModelSupport(modelPrefixes: [])
        )
        #expect(throws: ProviderManifestValidationError.self) {
            try ProviderManifestValidation.validate(manifest)
        }
    }
}

@Suite("ProviderCapabilitySlot")
struct ProviderCapabilitySlotTests {
    @Test("All eleven slots are enumerated")
    func allSlots() {
        #expect(ProviderCapabilitySlot.allCases.count == 11)
        #expect(ProviderCapabilitySlot.allCases.contains(.textInference))
        #expect(ProviderCapabilitySlot.allCases.contains(.webSearch))
    }
}
