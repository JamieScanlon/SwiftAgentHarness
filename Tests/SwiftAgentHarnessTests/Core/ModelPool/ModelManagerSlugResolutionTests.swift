import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Model slug + ModelReference resolution")
struct ModelManagerSlugResolutionTests {
    /// Stub matching production gateway split — implements only ``getAvailableModels``; resolve / resolveAll
    /// flow through the protocol-extension defaults (which build entries via ``ModelRegistryEntry/from(model:)``).
    private final class SlugStubModelProvider: APILayerModelManaging, Sendable {
        let models: [Model]
        init(models: [Model]) { self.models = models }
        func getAvailableModels() async -> [Model] { models }
    }

    private static func makeModel(id: UUID = UUID(), slug: String) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: slug,
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 4096
        )
    }

    @Test("ModelRegistryEntry.slug prefers primary binding endpointModelId")
    func registryEntrySlug() {
        let primary = ProviderBinding(
            providerId: "ollama",
            modelProtocol: .ollama,
            endpointModelId: "llama3.3:latest",
            serverURL: URL(string: "http://localhost:11434")!,
            priority: 0
        )
        let secondary = ProviderBinding(
            providerId: "lmstudio",
            modelProtocol: .lmStudio,
            endpointModelId: "meta/llama-3.3",
            serverURL: URL(string: "http://localhost:1234")!,
            priority: 10
        )
        let entry = ModelRegistryEntry(
            id: UUID(),
            displayName: "Llama 3.3",
            capabilities: [.completion],
            providers: [primary, secondary]
        )
        #expect(entry.slug == "llama3.3:latest")
        #expect(entry.allSlugs == ["llama3.3:latest", "meta/llama-3.3"])
    }

    @Test("ModelRegistryEntry.allSlugs dedupes repeated endpointModelId")
    func registryEntryAllSlugsDedupes() {
        let url = URL(string: "http://localhost:11434")!
        let a = ProviderBinding(providerId: "ollama", modelProtocol: .ollama, endpointModelId: "shared", serverURL: url, priority: 0)
        let b = ProviderBinding(providerId: "lmstudio", modelProtocol: .lmStudio, endpointModelId: "shared", serverURL: url, priority: 10)
        let entry = ModelRegistryEntry(
            id: UUID(),
            capabilities: [.completion],
            providers: [a, b]
        )
        #expect(entry.allSlugs == ["shared"])
    }

    @Test("resolve(.slug) finds an entry by canonical name via the protocol default impl")
    func protocolResolveBySlug() async throws {
        let id = UUID()
        let provider = SlugStubModelProvider(models: [
            Self.makeModel(id: UUID(), slug: "other-model"),
            Self.makeModel(id: id, slug: "llama3.3:latest"),
        ])

        let entry = try await provider.resolve(.slug("llama3.3:latest"))
        #expect(entry.id == id)
    }

    @Test("resolve throws ModelPoolError.unavailable when no entry matches")
    func resolveThrowsOnMiss() async {
        let provider = SlugStubModelProvider(models: [
            Self.makeModel(slug: "llama3.3:latest"),
        ])

        await #expect(throws: ModelPoolError.self) {
            _ = try await provider.resolve(.slug("does-not-exist"))
        }
        await #expect(throws: ModelPoolError.self) {
            _ = try await provider.resolve(.id(UUID()))
        }
    }

    @Test("resolve(_:) dispatches across .id, .slug, and .query")
    func unifiedResolveDispatch() async throws {
        let idA = UUID()
        let idB = UUID()
        let provider = SlugStubModelProvider(models: [
            Self.makeModel(id: idA, slug: "llama3.3:latest"),
            Self.makeModel(id: idB, slug: "qwen3:30b-a3b"),
        ])

        let byID = try await provider.resolve(.id(idB))
        #expect(byID.id == idB)

        let bySlug = try await provider.resolve(.slug("llama3.3:latest"))
        #expect(bySlug.id == idA)

        let byQuery = try await provider.resolve(.query(ModelQuery(mustIncludeCapabilities: [.completion])))
        #expect(byQuery.id == idA || byQuery.id == idB)
    }

    @Test("resolveAll(_:) returns single-element list for id/slug and ranked list for query")
    func unifiedResolveAll() async throws {
        let idA = UUID()
        let idB = UUID()
        let provider = SlugStubModelProvider(models: [
            Self.makeModel(id: idA, slug: "llama3.3:latest"),
            Self.makeModel(id: idB, slug: "qwen3:30b-a3b"),
        ])

        let bySlug = try await provider.resolveAll(.slug("qwen3:30b-a3b"))
        #expect(bySlug.count == 1)
        #expect(bySlug.first?.id == idB)

        await #expect(throws: ModelPoolError.self) {
            _ = try await provider.resolveAll(.slug("nope"))
        }

        let byQuery = try await provider.resolveAll(.query(ModelQuery(mustIncludeCapabilities: [.completion])))
        #expect(byQuery.count == 2)
    }

    @Test("resolveAll(.query) returns empty array (does not throw) when filters drop everything")
    func resolveAllQueryFiltersAllOut() async throws {
        let provider = SlugStubModelProvider(models: [
            Self.makeModel(slug: "llama3.3:latest"),
        ])

        let none = try await provider.resolveAll(.query(ModelQuery(mustIncludeCapabilities: [.vision])))
        #expect(none.isEmpty)
    }
}
