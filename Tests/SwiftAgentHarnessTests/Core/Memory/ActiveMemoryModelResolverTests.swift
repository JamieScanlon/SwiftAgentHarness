import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Active memory model resolver")
struct ActiveMemoryModelResolverTests {
    private func binding(
        protocol modelProtocol: ModelProtocol,
        slug: String,
        url: String = "http://localhost:1"
    ) -> ProviderBinding {
        ProviderBinding(
            providerId: modelProtocol.rawValue,
            modelProtocol: modelProtocol,
            endpointModelId: slug,
            serverURL: URL(string: url)!,
            priority: 0
        )
    }

    private func entry(
        slug: String,
        protocol modelProtocol: ModelProtocol,
        capabilities: Set<LLMCapability>,
        useClasses: [String] = []
    ) -> ModelRegistryEntry {
        ModelRegistryEntry(
            id: UUID(),
            displayName: slug,
            capabilities: capabilities,
            providers: [binding(protocol: modelProtocol, slug: slug)],
            useClasses: useClasses
        )
    }

    private func sessionModel(
        protocol modelProtocol: ModelProtocol = .ollama,
        capabilities: [LLMCapability] = [.completion, .tools]
    ) -> Model {
        Model(
            id: UUID(),
            protocol: modelProtocol,
            modelName: "session",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: capabilities,
            modelProtocol: modelProtocol
        )
    }

    @Test("pin with tools is used")
    func pinWithTools() async {
        let pinned = entry(slug: "pin-tools", protocol: .ollama, capabilities: [.completion, .tools])
        var config = MemoryConfiguration.default
        config.activeMemoryModelRef = pinned.slug
        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: sessionModel(),
            config: config,
            ranked: { ref in
                if case .slug(let s) = ref, s == pinned.slug { return [pinned] }
                return []
            }
        )
        #expect(resolved?.modelName == pinned.slug)
    }

    @Test("pin without tools falls through to query")
    func pinWithoutToolsFallsThrough() async {
        let pinned = entry(slug: "pin-no-tools", protocol: .ollama, capabilities: [.completion])
        let queryHit = entry(
            slug: "recall-hit",
            protocol: .ollama,
            capabilities: [.completion, .tools],
            useClasses: [ModelUseClass.memoryRecall]
        )
        var config = MemoryConfiguration.default
        config.activeMemoryModelRef = pinned.slug
        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: sessionModel(),
            config: config,
            ranked: { ref in
                switch ref {
                case .slug(let s) where s == pinned.slug:
                    return [pinned]
                case .query:
                    return [queryHit]
                default:
                    return []
                }
            }
        )
        #expect(resolved?.modelName == queryHit.slug)
    }

    @Test("query respects trust filter when session is local")
    func queryTrustFilter() async {
        let local = entry(slug: "local-tools", protocol: .ollama, capabilities: [.completion, .tools])
        let hosted = entry(slug: "hosted-tools", protocol: .openAIAPI, capabilities: [.completion, .tools])
        let parent = sessionModel(protocol: .ollama)
        let query = ActiveMemoryModelResolver.memoryRecallQuery(
            parentModel: parent,
            allowCrossProviderTrust: false
        )
        #expect(query.matches(local))
        #expect(!query.matches(hosted))

        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: parent,
            config: .default,
            ranked: { ref in
                guard case .query(let q) = ref else { return [] }
                return ModelQuery.rank(entries: [hosted, local], query: q)
            }
        )
        #expect(resolved?.modelName == local.slug)
        #expect(resolved?.modelProtocol == .ollama)
    }

    @Test("cross-provider opt-out allows hosted when session is local")
    func crossProviderOptOut() async {
        let hosted = entry(slug: "hosted-tools", protocol: .openAIAPI, capabilities: [.completion, .tools])
        var config = MemoryConfiguration.default
        config.activeMemoryAllowCrossProviderTrust = true
        let parent = sessionModel(protocol: .ollama)
        let query = ActiveMemoryModelResolver.memoryRecallQuery(
            parentModel: parent,
            allowCrossProviderTrust: true
        )
        #expect(query.allowedModelProtocols == nil)
        #expect(query.matches(hosted))

        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: parent,
            config: config,
            ranked: { ref in
                guard case .query = ref else { return [] }
                return [hosted]
            }
        )
        #expect(resolved?.modelName == hosted.slug)
    }

    @Test("empty query uses session model when it has tools")
    func sessionLastResort() async {
        let parent = sessionModel(protocol: .ollama, capabilities: [.completion, .tools])
        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: parent,
            config: .default,
            ranked: { _ in [] }
        )
        #expect(resolved?.id == parent.id)
    }

    @Test("empty query skips when session lacks tools")
    func skipWhenNothingResolves() async {
        let parent = sessionModel(protocol: .ollama, capabilities: [.completion])
        let resolved = await ActiveMemoryModelResolver.resolve(
            parentModel: parent,
            config: .default,
            ranked: { _ in [] }
        )
        #expect(resolved == nil)
    }

    @Test("default config has no active memory model pin")
    func defaultHasNoPin() {
        #expect(MemoryConfiguration.default.activeMemoryModelRef == nil)
        #expect(MemoryConfiguration.default.activeMemoryAllowCrossProviderTrust == false)
    }

    @Test("loader maps legacy activeMemoryModel to pin")
    func loaderLegacyPin() {
        let loaded = MemoryConfigurationLoader.load(fromMemoryObject: [
            "activeMemoryModel": "my-fast-model",
        ])
        #expect(loaded.activeMemoryModelRef == "my-fast-model")
    }
}

@Suite("ModelQuery provider trust")
struct ModelQueryProviderTrustTests {
    @Test("allowedModelProtocols filters primary binding")
    func allowedProtocolsFilter() {
        let ollama = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion, .tools],
            providers: [
                ProviderBinding(
                    providerId: "ollama",
                    modelProtocol: .ollama,
                    endpointModelId: "local",
                    serverURL: URL(string: "http://localhost:11434")!,
                    priority: 0
                )
            ]
        )
        let openAI = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion, .tools],
            providers: [
                ProviderBinding(
                    providerId: "openai",
                    modelProtocol: .openAIAPI,
                    endpointModelId: "gpt",
                    serverURL: URL(string: "https://api.openai.com")!,
                    priority: 0
                )
            ]
        )
        let localOnly = ModelQuery(
            mustIncludeCapabilities: [.tools],
            allowedModelProtocols: [.ollama, .lmStudio]
        )
        #expect(localOnly.matches(ollama))
        #expect(!localOnly.matches(openAI))
    }
}
