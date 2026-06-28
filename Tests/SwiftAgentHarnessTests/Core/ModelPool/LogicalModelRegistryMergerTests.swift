import Foundation
import SwiftAgentKit
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

@Suite("LogicalModelRegistryMerger")
struct LogicalModelRegistryMergerTests {
    private static let anthropicSonnetID = UUID(uuidString: "b2000002-0002-4000-8000-000000000002")!
    private static let openRouterSonnetID = UUID(uuidString: "c3000003-0003-4000-8000-000000000001")!
    private static let anthropicEndpoint = URL(string: "https://api.anthropic.com")!
    private static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1")!

    private static var defaultPreference: ModelPoolProviderPreferenceConfiguration {
        .specDefaults
    }

    private static func bundledSonnetEntry(providerID: String, endpoint: URL) throws -> ModelRegistryEntry {
        let entries = try ProviderCatalogLoader.decodeBundledCatalog(for: providerID)
        let endpointModelId = providerID == "openrouter"
            ? "anthropic/claude-sonnet-4-6"
            : "claude-sonnet-4-6"
        let catalog = try #require(entries.first { $0.endpointModelId == endpointModelId })
        return catalog.toRegistryEntry(providerID: providerID, serverURL: endpoint)
    }

    @Test("merges Anthropic and OpenRouter Sonnet into one multi-binding entry")
    func mergesSonnetAcrossProviders() throws {
        let anthropic = try Self.bundledSonnetEntry(providerID: "anthropic", endpoint: Self.anthropicEndpoint)
        let openRouter = try Self.bundledSonnetEntry(providerID: "openrouter", endpoint: Self.openRouterEndpoint)

        let merged = LogicalModelRegistryMerger.merge(
            entries: [anthropic, openRouter],
            providerPreference: Self.defaultPreference
        )

        #expect(merged.count == 1)
        let entry = try #require(merged[Self.anthropicSonnetID])
        #expect(entry.canonicalModelKey == "claude-sonnet-4-6")
        #expect(entry.family == "claude-sonnet")
        #expect(entry.providers.count == 2)
        #expect(entry.providers[0].providerId == "anthropic")
        #expect(entry.providers[0].priority == 0)
        #expect(entry.providers[1].providerId == "openrouter")
        #expect(entry.providers[1].priority == 40)
        #expect(entry.slug == "claude-sonnet-4-6")
        #expect(entry.allSlugs.contains("anthropic/claude-sonnet-4-6"))
        #expect(merged[Self.openRouterSonnetID] == nil)
    }

    @Test("preserves per-binding cost from each source entry")
    func preservesPerBindingCost() throws {
        let anthropic = try Self.bundledSonnetEntry(providerID: "anthropic", endpoint: Self.anthropicEndpoint)
        let openRouter = try Self.bundledSonnetEntry(providerID: "openrouter", endpoint: Self.openRouterEndpoint)

        let merged = LogicalModelRegistryMerger.merge(
            entries: [anthropic, openRouter],
            providerPreference: Self.defaultPreference
        )
        let entry = try #require(merged[Self.anthropicSonnetID])

        #expect(entry.cost?.cachedInputPer1MUSD == 0.3)
        #expect(entry.providers[0].cost?.cachedInputPer1MUSD == 0.3)
        #expect(entry.providers[1].cost?.cachedInputPer1MUSD == nil)
        #expect(entry.providers[1].cost?.inputPer1MUSD == 3.0)
    }

    @Test("derived OpenRouter key joins only on exact explicit-key match")
    func derivedOpenRouterExactMatch() throws {
        let anthropicBinding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: Self.anthropicEndpoint,
            priority: 0
        )
        let anthropic = ModelRegistryEntry(
            id: Self.anthropicSonnetID,
            family: "claude-sonnet",
            displayName: "Claude Sonnet 4.6",
            capabilities: [.completion, .tools],
            providers: [anthropicBinding],
            canonicalModelKey: "claude-sonnet-4-6"
        )
        let openRouterBinding = ProviderBinding(
            providerId: "openrouter",
            modelProtocol: .openAIAPI,
            endpointModelId: "anthropic/claude-sonnet-4-6",
            serverURL: Self.openRouterEndpoint,
            priority: 0
        )
        let derivedCandidate = ModelRegistryEntry(
            id: UUID(),
            displayName: "Dynamic Sonnet",
            capabilities: [.completion],
            providers: [openRouterBinding]
        )

        let merged = LogicalModelRegistryMerger.merge(
            entries: [anthropic, derivedCandidate],
            providerPreference: Self.defaultPreference
        )

        #expect(merged.count == 1)
        let entry = try #require(merged[Self.anthropicSonnetID])
        #expect(entry.providers.count == 2)
    }

    @Test("derived OpenRouter key does not fuzzy-merge unrelated models")
    func noFuzzyMerge() {
        let anthropicBinding = ProviderBinding(
            providerId: "anthropic",
            modelProtocol: .anthropic,
            endpointModelId: "claude-sonnet-4-6",
            serverURL: Self.anthropicEndpoint,
            priority: 0
        )
        let anthropic = ModelRegistryEntry(
            id: Self.anthropicSonnetID,
            capabilities: [.completion],
            providers: [anthropicBinding],
            canonicalModelKey: "claude-sonnet-4-6"
        )
        let unrelatedBinding = ProviderBinding(
            providerId: "openrouter",
            modelProtocol: .openAIAPI,
            endpointModelId: "anthropic/claude-opus-4-6",
            serverURL: Self.openRouterEndpoint,
            priority: 0
        )
        let unrelated = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            providers: [unrelatedBinding]
        )

        let merged = LogicalModelRegistryMerger.merge(
            entries: [anthropic, unrelated],
            providerPreference: Self.defaultPreference
        )

        #expect(merged.count == 2)
    }

    @Test("entries without a canonical key pass through unchanged")
    func singletonPassthrough() {
        let binding = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "llama3.3:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let id = UUID()
        let entry = ModelRegistryEntry(
            id: id,
            capabilities: [.completion],
            providers: [binding]
        )

        let merged = LogicalModelRegistryMerger.merge(
            entries: [entry],
            providerPreference: Self.defaultPreference
        )

        #expect(merged.count == 1)
        #expect(merged[id]?.providers.count == 1)
    }
}

@Suite("LogicalModelKey")
struct LogicalModelKeyTests {
    @Test("inferredFamily drops trailing numeric version segments")
    func inferredFamily() {
        #expect(LogicalModelKey.inferredFamily(from: "claude-sonnet-4-6") == "claude-sonnet")
        #expect(LogicalModelKey.inferredFamily(from: "claude-opus-4-6") == "claude-opus")
    }

    @Test("deriveCanonicalKey matches OpenRouter vendor/model tail exactly")
    func deriveCanonicalKey() {
        let explicit: Set<String> = ["claude-sonnet-4-6"]
        #expect(
            LogicalModelKey.deriveCanonicalKey(
                providerId: "openrouter",
                endpointModelId: "anthropic/claude-sonnet-4-6",
                explicitKeys: explicit
            ) == "claude-sonnet-4-6"
        )
        #expect(
            LogicalModelKey.deriveCanonicalKey(
                providerId: "openrouter",
                endpointModelId: "anthropic/claude-opus-4-6",
                explicitKeys: explicit
            ) == nil
        )
        #expect(
            LogicalModelKey.deriveCanonicalKey(
                providerId: "anthropic",
                endpointModelId: "claude-sonnet-4-6",
                explicitKeys: explicit
            ) == nil
        )
    }
}

@Suite("ModelManager multi-binding discovery merge")
struct ModelManagerMultiBindingDiscoveryTests {
    @Test("bundled frontier catalogs merge Sonnet into one registry row")
    func bundledCatalogMerge() throws {
        let anthropic = try ProviderCatalogLoader.decodeBundledCatalog(for: "anthropic")
        let openRouter = try ProviderCatalogLoader.decodeBundledCatalog(for: "openrouter")
        ProviderTestManifestSupport.prepareRegistry()
        let anthropicEndpoint = try #require(try ProviderTestManifestSupport.loadManifest(for: "anthropic").defaultEndpoint?.baseURL)
        let openRouterEndpoint = try #require(try ProviderTestManifestSupport.loadManifest(for: "openrouter").defaultEndpoint?.baseURL)

        let discovered = anthropic.map {
            $0.toRegistryEntry(providerID: "anthropic", serverURL: anthropicEndpoint)
        } + openRouter.map {
            $0.toRegistryEntry(providerID: "openrouter", serverURL: openRouterEndpoint)
        }

        let merged = LogicalModelRegistryMerger.merge(
            entries: discovered,
            providerPreference: .specDefaults
        )

        let sonnetRows = merged.values.filter { $0.canonicalModelKey == "claude-sonnet-4-6" }
        #expect(sonnetRows.count == 1)
        let sonnet = try #require(sonnetRows.first)
        #expect(sonnet.providers.count == 2)

        let bySlugAnthropic = merged.values.first { $0.allSlugs.contains("claude-sonnet-4-6") }
        let bySlugOpenRouter = merged.values.first { $0.allSlugs.contains("anthropic/claude-sonnet-4-6") }
        #expect(bySlugAnthropic?.id == bySlugOpenRouter?.id)
    }
}

@Suite("ModelPoolProviderPreferenceConfiguration")
struct ModelPoolProviderPreferenceConfigurationTests {
    @Test("loads order from settings JSON")
    func loadsFromSettings() {
        let settings: [String: Any] = [
            "modelPoolProviderPreference": [
                "order": ["openrouter", "anthropic"],
            ],
        ]
        let config = ModelPoolProviderPreferenceConfiguration.configuration(fromSettingsJSON: settings)
        #expect(config.order == ["openrouter", "anthropic"])
    }

    @Test("ServerConfig override replaces order")
    func serverConfigOverride() {
        let base = ModelPoolProviderPreferenceConfiguration(order: ["anthropic", "openrouter"])
        var server = ServerConfig()
        server.modelPoolProviderPreferenceOrderOverride = ["openrouter", "anthropic"]
        #expect(base.applyingOverrides(serverConfig: server).order == ["openrouter", "anthropic"])
    }
}
