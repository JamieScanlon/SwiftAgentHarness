import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ProviderManifest decode")
struct ProviderManifestDecodeTests {
    @Test("Static catalog manifests decode from bundled JSON")
    func bundledManifestsDecode() throws {
        let bundledIDs: Set<ProviderID> = ["openai", "anthropic", "ollama", "lmstudio", "openrouter"]
        for manifest in ProviderManifests.all where bundledIDs.contains(manifest.id) {
            guard let data = ProviderManifestLoader.bundledManifestData(for: manifest.id) else {
                Issue.record("Missing bundled manifest for \(manifest.id)")
                continue
            }
            let decoded = try JSONDecoder().decode(ProviderManifest.self, from: data)
            #expect(decoded.id == manifest.id)
            #expect(decoded.label == manifest.label)
            #expect(decoded.providerEndpoints.count == manifest.providerEndpoints.count)
            #expect(decoded.modelSupport.modelPrefixes == manifest.modelSupport.modelPrefixes)
        }
    }

    @Test("Built-in catalog passes validation")
    func builtInCatalogValidates() throws {
        try ProviderManifestValidation.validateAll(ProviderManifests.all)
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
