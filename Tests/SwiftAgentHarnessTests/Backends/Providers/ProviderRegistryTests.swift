import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test("Built-in providers register")
    func builtInProviders() {
        ProviderTestSupport.registerDefaultsForTesting()
        let manifests = ProviderRegistry.allManifests()
        #expect(manifests.map(\.id).contains("openai"))
        #expect(manifests.map(\.id).contains("anthropic"))
        #expect(manifests.map(\.id).contains("ollama"))
        #expect(manifests.map(\.id).contains("lmstudio"))
        #expect(manifests.map(\.id).contains("openrouter"))
    }

    @Test("Text inference lookup by provider id")
    func textInferenceLookup() {
        ProviderTestSupport.registerDefaultsForTesting()
        #expect(ProviderRegistry.textInferenceProvider(for: "anthropic") != nil)
    }

    @Test("Missing provider throws")
    func missingProvider() {
        ProviderTestSupport.registerDefaultsForTesting()
        #expect(throws: ProviderRegistryError.self) {
            try ProviderRegistry.registration(for: "missing")
        }
    }

    @Test("Inspect returns validated manifests")
    func inspect() {
        ProviderTestSupport.registerDefaultsForTesting()
        let inspected = ProviderRegistry.inspect()
        #expect(!inspected.isEmpty)
    }

    @Test("Anthropic bootstrap registers media understanding stub")
    func anthropicMediaUnderstandingStub() throws {
        ProviderTestSupport.registerDefaultsForTesting()
        let slots = try ProviderRegistry.registeredSlots(for: "anthropic")
        #expect(slots.contains(.mediaUnderstanding))
    }

    @Test("allCLIInferenceBackends includes openai codex stub")
    func allCLIBackends() {
        ProviderTestSupport.registerDefaultsForTesting()
        let ids = ProviderRegistry.allCLIInferenceBackends().map(\.cliBackendID)
        #expect(ids.contains("openai-codex"))
    }

    @Test("Duplicate registration throws")
    func duplicateRegistrationThrows() throws {
        ProviderTestSupport.registerDefaultsForTesting()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        #expect(throws: ProviderRegistryError.duplicateRegistration("openai")) {
            try ProviderRegistry.register(ProviderRegistration(
                manifest: manifest,
                textInference: OpenAITextInferenceProvider(manifest: manifest),
                cliInferenceBackends: [
                    StubCLIInferenceBackendProvider(manifest: manifest, cliBackendID: "openai-codex"),
                ]
            ))
        }
    }

    @Test("ensureBootstrapped does not deadlock when hook registers providers")
    func ensureBootstrappedDoesNotDeadlock() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.installBootstrap {
            ProviderTestSupport.registerDefaultsForTesting()
        }
        ProviderRegistry.ensureBootstrapped()
        #expect(!ProviderRegistry.allManifests().isEmpty)
    }
}

@Suite("Provider capability slot scaffolds")
struct ProviderCapabilitySlotScaffoldTests {
    @Test("OpenAI manifest declares multiple capability slots")
    func openAISlots() throws {
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        let slots = manifest.capabilitySlots
        #expect(slots.contains(.textInference))
        #expect(slots.contains(.speech))
        #expect(slots.contains(.imageGeneration))
    }

    @Test("Stub speech provider carries manifest")
    func stubSpeechProvider() throws {
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        let stub = StubSpeechProvider(manifest: manifest)
        #expect(stub.manifest.id == "openai")
    }
}

@Suite("ProviderRuntimeHooks")
struct ProviderRuntimeHooksTests {
    @Test("System prompt contribution merges cache boundary")
    func cacheBoundaryMerge() {
        let merged = ProviderPromptContribution.merge(
            basePrompt: "base",
            contribution: ProviderSystemPromptContribution(stablePrefix: "prefix")
        )
        #expect(merged.contains(ProviderPromptContribution.cacheBoundaryMarker))
        #expect(merged.contains("prefix"))
        #expect(merged.contains("base"))
    }
}
