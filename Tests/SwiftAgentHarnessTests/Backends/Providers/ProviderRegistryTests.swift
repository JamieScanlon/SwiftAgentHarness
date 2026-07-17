import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("ProviderRegistry", .serialized)
struct ProviderRegistryTests {
    @Test("Built-in providers register")
    func builtInProviders() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        let manifests = ProviderRegistry.allManifests()
        #expect(manifests.map(\.id).contains("openai"))
        #expect(manifests.map(\.id).contains("anthropic"))
        #expect(manifests.map(\.id).contains("ollama"))
        #expect(manifests.map(\.id).contains("lmstudio"))
        #expect(manifests.map(\.id).contains("openrouter"))
    }

    @Test("Text inference lookup by provider id")
    func textInferenceLookup() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        #expect(ProviderRegistry.textInferenceProvider(for: "anthropic") != nil)
    }

    @Test("Missing provider throws")
    func missingProvider() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        #expect(throws: ProviderRegistryError.self) {
            try ProviderRegistry.registration(for: "missing")
        }
    }

    @Test("Inspect returns validated manifests")
    func inspect() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        let inspected = ProviderRegistry.inspect()
        #expect(!inspected.isEmpty)
    }

    @Test("Anthropic bootstrap registers media understanding stub")
    func anthropicMediaUnderstandingStub() throws {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        let slots = try ProviderRegistry.registeredSlots(for: "anthropic")
        #expect(slots.contains(.mediaUnderstanding))
    }

    @Test("allCLIInferenceBackends includes openai codex stub")
    func allCLIBackends() {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
        let ids = ProviderRegistry.allCLIInferenceBackends().map(\.cliBackendID)
        #expect(ids.contains("openai-codex"))
    }

    @Test("Duplicate registration throws")
    func duplicateRegistrationThrows() throws {
        ProviderTestSupport.registerDefaultsForTesting(
            inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
        )
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
        ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            ProviderRegistry.installBootstrap {
                ProviderTestSupport.registerDefaultsForTesting(
                    inferenceRuntimes: InferenceRuntimeCatalogFixtures.defaultTestInferenceRuntimes
                )
            }
            ProviderRegistry.ensureBootstrapped()
            #expect(!ProviderRegistry.allManifests().isEmpty)
        }
    }

    @Test("API-server providers are omitted when inferenceRuntimes is empty")
    func emptyInferenceRuntimesOmitsAPIServerProviders() {
        ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            ProviderLifecycle.resetForTesting()
            ProviderAdapterFactoryRegistry.resetForTesting()
            registerDefaults(options: .init(installBootstrapHook: false, inferenceRuntimes: []))
            let ids = Set(ProviderRegistry.allManifests().map(\.id))
            #expect(ids.contains("openai"))
            #expect(ids.contains("anthropic"))
            #expect(ids.contains("openrouter"))
            #expect(!ids.contains("ollama"))
            #expect(!ids.contains("lmstudio"))
        }
    }

    @Test("Host can register a custom provider id with an adapter kind")
    func customProviderIDForAdapterKind() {
        ProviderTestManifestSupport.withRegistryIsolation {
            ProviderRegistry.resetForTesting()
            ProviderLifecycle.resetForTesting()
            ProviderAdapterFactoryRegistry.resetForTesting()
            let runtime = InferenceRuntimeConfig(
                providerID: "home-lab",
                label: "Home lab",
                adapterKind: .ollama,
                serverURL: URL(string: "http://gpu.example:11434")!,
                modelIDMap: ["gemma3:27b": InferenceRuntimeCatalogFixtures.ollamaModelIDMap["gemma3:27b"]!]
            )
            registerDefaults(options: .init(installBootstrapHook: false, inferenceRuntimes: [runtime]))
            let ids = Set(ProviderRegistry.allManifests().map(\.id))
            #expect(ids.contains("home-lab"))
            #expect(!ids.contains("ollama"))
            let provider = ProviderRegistry.textInferenceProvider(for: "home-lab") as? OllamaTextInferenceProvider
            #expect(provider?.runtime.serverURL.absoluteString == "http://gpu.example:11434")
            #expect(provider?.staticCatalogEntries().map(\.endpointModelId) == ["gemma3:27b"])
        }
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
    @Test("System prompt contribution maps provider sections to canonical names")
    func typedContributionMapping() {
        let wire = ProviderSystemPromptContribution(
            stablePrefix: "prefix",
            sectionOverrides: [
                .interactionStyle: "be concise",
                .toolCallStyle: "call tools directly",
            ]
        )
        let typed = ProviderPromptContribution.systemPromptContribution(from: wire)
        #expect(typed?.stablePrefix == "prefix")
        #expect(typed?.sectionOverrides[.dynamicAdditions] == "be concise")
        #expect(typed?.sectionOverrides[.toolGuidance] == "call tools directly")
    }

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
