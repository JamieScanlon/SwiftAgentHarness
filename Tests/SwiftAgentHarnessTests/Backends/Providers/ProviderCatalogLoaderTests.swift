import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ProviderCatalogLoader")
struct ProviderCatalogLoaderTests {
    @Test("Bundled frontier catalogs decode from module resources")
    func bundledCatalogsDecode() throws {
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

    @Test("OpenAI gpt-4o row carries compat metadata")
    func openAICompat() throws {
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "openai")
        let gpt4o = try #require(entries.first { $0.endpointModelId == "gpt-4o" })
        #expect(gpt4o.compat?.supportsEagerToolInputStreaming == false)
    }

    @Test("Anthropic sonnet row carries thinking compat")
    func anthropicThinkingCompat() throws {
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "anthropic")
        let sonnet = try #require(entries.first { $0.endpointModelId == "claude-sonnet-4-6" })
        #expect(sonnet.compat?.thinkingFormat == "anthropic-extended-thinking")
        #expect(sonnet.compat?.supportsEagerToolInputStreaming == true)
    }

    @Test("toRegistryEntry forwards compat onto ModelRegistryEntry")
    func compatForwardedToRegistry() throws {
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: "anthropic")
        let sonnet = try #require(entries.first { $0.endpointModelId == "claude-sonnet-4-6" })
        let endpoint = try #require(ProviderManifests.anthropic.defaultEndpoint)
        let registryEntry = sonnet.toRegistryEntry(
            providerID: "anthropic",
            serverURL: endpoint.baseURL
        )
        #expect(registryEntry.compat?.thinkingFormat == "anthropic-extended-thinking")
        #expect(registryEntry.cost?.inputPer1MUSD == 3.0)
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
}

@Suite("Frontier provider static catalogs")
struct FrontierProviderStaticCatalogTests {
    @Test("OpenAI static catalog is non-empty")
    func openAIStaticCatalog() {
        let provider = OpenAITextInferenceProvider()
        #expect(!provider.staticCatalogEntries().isEmpty)
    }

    @Test("Anthropic static catalog is non-empty")
    func anthropicStaticCatalog() {
        let provider = AnthropicTextInferenceProvider()
        #expect(!provider.staticCatalogEntries().isEmpty)
    }

    @Test("OpenRouter static seed is non-empty")
    func openRouterStaticSeed() {
        let provider = OpenRouterTextInferenceProvider()
        #expect(!provider.staticCatalogEntries().isEmpty)
    }
}

@Suite("OpenRouterCatalogDiscovery")
struct OpenRouterCatalogDiscoveryTests {
    @Test("Static seed retains curated cost over API pricing")
    func staticSeedWinsOnCost() async throws {
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let curated = try #require(staticEntries.first { $0.endpointModelId == "openai/gpt-4o" })
        let curatedCost = try #require(curated.modelConfig.hardcodedCost)

        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: ProviderManifests.openrouter,
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
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let dynamicID = "meta-llama/llama-4-scout"
        let expectedUUID = ProviderCatalogStableID.registryUUID(
            providerID: "openrouter",
            endpointModelId: dynamicID
        )

        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: ProviderManifests.openrouter,
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
    func fetchFailureFallback() async {
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let entries = await OpenRouterCatalogDiscovery.discoverEntries(
            manifest: ProviderManifests.openrouter,
            staticEntries: staticEntries,
            logger: nil,
            fetchModels: { _, _ in
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(entries.count == staticEntries.count)
    }

    @Test("resolveDynamicModel uses static seed then stable fallback")
    func resolveDynamicModel() {
        let staticEntries = bundledStaticCatalogEntries(providerID: "openrouter")
        let context = ProviderDynamicModelContext(
            endpointModelId: "anthropic/claude-sonnet-4-6",
            serverURL: ProviderManifests.openrouter.defaultEndpoint!.baseURL
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
            serverURL: ProviderManifests.openrouter.defaultEndpoint!.baseURL
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
