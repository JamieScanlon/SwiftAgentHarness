import Foundation
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("ProviderCatalogLoader", .serialized)
struct ProviderCatalogLoaderTests {
    private func prepare() {
        ProviderTestManifestSupport.activateProviderResources()
    }

    @Test("Bundled frontier catalogs decode from module resources")
    func bundledCatalogsDecode() throws {
        prepare()
        for providerID in ["openai", "anthropic", "openrouter"] {
            let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: providerID)
            #expect(!entries.isEmpty, "Expected non-empty catalog for \(providerID)")
            for entry in entries {
                #expect(!entry.endpointModelId.isEmpty)
                #expect(entry.modelConfig.hardcodedCost?.inputPer1MUSD != nil)
                #expect(entry.modelConfig.hardcodedCost?.outputPer1MUSD != nil)
                #expect(entry.maxContextLength != nil)
                #expect(!(entry.capabilities ?? []).isEmpty)
            }
        }
    }

    @Test("OpenAI gpt-4o row carries strict tool schema compat")
    func openAICompat() throws {
        prepare()
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "openai")
        let gpt4o = try #require(entries.first { $0.endpointModelId == "gpt-4o" })
        #expect(gpt4o.compat?.supportsEagerToolInputStreaming == true)
        #expect(gpt4o.compat?.toolSchemaProfile?.toolSchemaMode == .openAIStrict)
    }

    @Test("Anthropic sonnet row carries thinking compat")
    func anthropicThinkingCompat() throws {
        prepare()
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "anthropic")
        let sonnet = try #require(entries.first { $0.endpointModelId == "claude-sonnet-4-6" })
        #expect(sonnet.compat?.thinkingFormat == "anthropic-extended-thinking")
        #expect(sonnet.compat?.supportsEagerToolInputStreaming == true)
        #expect(sonnet.canonicalModelKey == "claude-sonnet-4-6")
        #expect(sonnet.modelFamily == "claude-sonnet")
    }

    @Test("OpenRouter sonnet row shares canonicalModelKey with Anthropic")
    func openRouterCanonicalKey() throws {
        prepare()
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "openrouter")
        let sonnet = try #require(entries.first { $0.endpointModelId == "anthropic/claude-sonnet-4-6" })
        #expect(sonnet.canonicalModelKey == "claude-sonnet-4-6")
        #expect(sonnet.modelFamily == "claude-sonnet")
    }

    @Test("toRegistryEntry forwards compat onto ModelRegistryEntry")
    func compatForwardedToRegistry() throws {
        prepare()
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "anthropic")
        let sonnet = try #require(entries.first { $0.endpointModelId == "claude-sonnet-4-6" })
        let endpoint = try #require(try ProviderTestManifestSupport.loadManifest(for: "anthropic").defaultEndpoint)
        let registryEntry = sonnet.toRegistryEntry(
            providerID: "anthropic",
            serverURL: endpoint.baseURL
        )
        #expect(registryEntry.compat?.thinkingFormat == "anthropic-extended-thinking")
        #expect(registryEntry.cost?.inputPer1MUSD == 3.0)
        #expect(registryEntry.family == "claude-sonnet")
        #expect(registryEntry.family != "anthropic")
        #expect(registryEntry.canonicalModelKey == "claude-sonnet-4-6")
        #expect(registryEntry.providers.first?.cost?.inputPer1MUSD == 3.0)
    }

    @Test("Stable registry UUID is deterministic")
    func stableRegistryUUID() {
        let first = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: "vendor/model-a"
        )
        let second = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: "vendor/model-a"
        )
        let other = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: "vendor/model-b"
        )
        #expect(first == second)
        #expect(first != other)
    }

    @Test("Bundled provider overrides decode family system prompt contributions")
    func bundledOverridesDecode() {
        prepare()
        let binding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: URL(string: "https://api.anthropic.com")!
        )
        let contribution = ProviderCatalogLoader.systemPromptContribution(for: binding)
        #expect(contribution?.stablePrefix?.contains("Claude Sonnet") == true)
    }
}

@Suite("Frontier provider static catalogs")
struct FrontierProviderStaticCatalogTests {
    @Test("OpenAI static catalog is non-empty")
    func openAIStaticCatalog() throws {
        ProviderTestManifestSupport.activateProviderResources()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openai")
        let provider = OpenAITextInferenceProvider(manifest: manifest)
        #expect(!provider.staticCatalogEntries().isEmpty)
    }

    @Test("Anthropic static catalog is non-empty")
    func anthropicStaticCatalog() throws {
        ProviderTestManifestSupport.activateProviderResources()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "anthropic")
        let provider = AnthropicTextInferenceProvider(manifest: manifest)
        #expect(!provider.staticCatalogEntries().isEmpty)
    }

    @Test("OpenRouter static seed is non-empty")
    func openRouterStaticSeed() throws {
        ProviderTestManifestSupport.activateProviderResources()
        let manifest = try ProviderTestManifestSupport.loadManifest(for: "openrouter")
        let provider = OpenRouterTextInferenceProvider(manifest: manifest)
        #expect(!provider.staticCatalogEntries().isEmpty)
    }
}

@Suite("OpenRouterCatalogDiscovery")
struct OpenRouterCatalogDiscoveryTests {
    @Test("Static seed retains curated cost over API pricing")
    func staticSeedWinsOnCost() async throws {
        ProviderTestManifestSupport.activateProviderResources()
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let curated = try #require(staticEntries.first { $0.endpointModelId == "openai/gpt-4o" })
        let curatedCost = try #require(curated.modelConfig.hardcodedCost)

        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: try ProviderTestManifestSupport.loadManifest(for: "openrouter"),
            staticEntries: staticEntries,
            logger: nil,
            fetchModels: { _, _ in
                [
                    OpenRouterModelRow(
                        id: "openai/gpt-4o",
                        name: "GPT-4o",
                        context_length: 128000,
                        pricing: OpenRouterModelPricing(prompt: "0.000001", completion: "0.000002"),
                        architecture: nil
                    ),
                ]
            }
        )

        let entry = try #require(entries.first { $0.primaryBinding?.endpointModelId == "openai/gpt-4o" })
        #expect(entry.cost == curatedCost)
        #expect(entry.cost?.inputPer1MUSD == 2.5)
    }

    @Test("Unknown API model gets API-derived cost and stable UUID")
    func dynamicModelFromAPI() async throws {
        ProviderTestManifestSupport.activateProviderResources()
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let dynamicID = "meta-llama/llama-4-scout"
        let expectedUUID = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: dynamicID
        )

        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: try ProviderTestManifestSupport.loadManifest(for: "openrouter"),
            staticEntries: staticEntries,
            logger: nil,
            fetchModels: { _, _ in
                [
                    OpenRouterModelRow(
                        id: dynamicID,
                        name: "Llama 4 Scout",
                        context_length: 131072,
                        pricing: OpenRouterModelPricing(prompt: "0.0000005", completion: "0.0000015"),
                        architecture: OpenRouterModelArchitecture(
                            modality: "text->text",
                            input_modalities: ["text"],
                            output_modalities: ["text"]
                        )
                    ),
                ]
            }
        )

        let entry = try #require(entries.first { $0.id == expectedUUID })
        #expect(entry.cost?.inputPer1MUSD == 0.5)
        #expect(entry.cost?.outputPer1MUSD == 1.5)
        #expect(entry.maxContextLength == 131072)
    }

    @Test("Fetch failure falls back to static seed only")
    func fetchFailureFallback() async throws {
        ProviderTestManifestSupport.activateProviderResources()
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: try ProviderTestManifestSupport.loadManifest(for: "openrouter"),
            staticEntries: staticEntries,
            logger: nil,
            fetchModels: { _, _ in
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(entries.count == staticEntries.count)
    }

    @Test("resolveDynamicModel uses static seed then stable fallback")
    func resolveDynamicModel() throws {
        ProviderTestManifestSupport.activateProviderResources()
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let context = ProviderDynamicModelContext(
            endpointModelId: "anthropic/claude-sonnet-4-6",
            serverURL: try ProviderTestManifestSupport.loadManifest(for: "openrouter").defaultEndpoint!.baseURL
        )
        let resolved = OpenRouterCatalogDiscovery.resolveDynamicModel(
            context: context,
            providerID: "openrouter",
            staticEntries: staticEntries
        )
        #expect(resolved?.endpointModelId == "anthropic/claude-sonnet-4-6")
        #expect(resolved?.compat?.thinkingFormat == "anthropic-extended-thinking")

        let dynamicContext = ProviderDynamicModelContext(
            endpointModelId: "vendor/unknown-model",
            serverURL: try ProviderTestManifestSupport.loadManifest(for: "openrouter").defaultEndpoint!.baseURL
        )
        let dynamic = OpenRouterCatalogDiscovery.resolveDynamicModel(
            context: dynamicContext,
            providerID: "openrouter",
            staticEntries: staticEntries
        )
        let expectedID = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: "vendor/unknown-model"
        )
        #expect(dynamic?.registryID == expectedID)
    }

    @Test("perTokenUSDToPer1M converts OpenRouter pricing strings")
    func pricingConversion() {
        #expect(OpenRouterCatalogDiscovery.perTokenUSDToPer1M("0.000003") == 3.0)
        #expect(OpenRouterCatalogDiscovery.costBudget(from: OpenRouterModelPricing(
            prompt: "0.000003",
            completion: "0.000015",
            input_cache_read: nil
        ))?.combinedPer1MUSD == 18.0)
    }
}
