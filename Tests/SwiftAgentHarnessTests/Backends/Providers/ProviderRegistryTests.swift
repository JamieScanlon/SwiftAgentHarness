import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test("Built-in providers register")
    func builtInProviders() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        let manifests = ProviderRegistry.allManifests()
        #expect(manifests.map(\.id).contains("openai"))
        #expect(manifests.map(\.id).contains("anthropic"))
        #expect(manifests.map(\.id).contains("ollama"))
        #expect(manifests.map(\.id).contains("lmstudio"))
        #expect(manifests.map(\.id).contains("openrouter"))
    }

    @Test("Text inference lookup by provider id")
    func textInferenceLookup() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        #expect(ProviderRegistry.textInferenceProvider(for: "anthropic") != nil)
    }

    @Test("Missing provider throws")
    func missingProvider() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        #expect(throws: ProviderRegistryError.self) {
            try ProviderRegistry.registration(for: "missing")
        }
    }

    @Test("Inspect returns validated manifests")
    func inspect() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        let inspected = ProviderRegistry.inspect()
        #expect(!inspected.isEmpty)
    }

    @Test("Anthropic bootstrap registers media understanding stub")
    func anthropicMediaUnderstandingStub() throws {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        let slots = try ProviderRegistry.registeredSlots(for: "anthropic")
        #expect(slots.contains(.mediaUnderstanding))
    }

    @Test("allCLIInferenceBackends includes openai codex stub")
    func allCLIBackends() {
        ProviderRegistry.resetForTesting()
        ProviderRegistry.bootstrapBuiltInsIfNeeded()
        let ids = ProviderRegistry.allCLIInferenceBackends().map(\.cliBackendID)
        #expect(ids.contains("openai-codex"))
    }
}

@Suite("Provider capability slot scaffolds")
struct ProviderCapabilitySlotScaffoldTests {
    @Test("OpenAI manifest declares multiple capability slots")
    func openAISlots() {
        let slots = ProviderManifests.openai.capabilitySlots
        #expect(slots.contains(.textInference))
        #expect(slots.contains(.speech))
        #expect(slots.contains(.imageGeneration))
    }

    @Test("Stub speech provider carries manifest")
    func stubSpeechProvider() {
        let stub = StubSpeechProvider(manifest: ProviderManifests.openai)
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
