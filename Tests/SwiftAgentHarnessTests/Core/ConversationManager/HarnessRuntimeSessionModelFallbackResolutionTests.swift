import EasyJSON
import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSession dispatch model fallback resolution")
struct HarnessRuntimeSessionModelFallbackResolutionTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeEntry(
        id: UUID = UUID(),
        slug: String,
        useClasses: [String] = [],
        family: String? = "test-family"
    ) -> ModelRegistryEntry {
        ModelRegistryEntry(
            id: id,
            family: family,
            displayName: slug,
            capabilities: [.completion],
            providers: [
                ProviderBinding(
                    providerId: "openai",
                    modelProtocol: .openAIAPI,
                    endpointModelId: slug,
                    serverURL: URL(string: "http://localhost:1234")!,
                    priority: 0
                )
            ],
            useClasses: useClasses
        )
    }

    private func modeRegistryWithFallbackProfile() -> ModeRegistryPortAdapter {
        let config = ModeProfileConfiguration(
            profiles: [
                .init(
                    id: "dispatch-mode",
                    extends: InteractionMode.chat.rawValue,
                    model: .object([
                        "query": .string("primary-query"),
                        "fallback": .string("fallback-query"),
                    ])
                ),
            ],
            diagnostics: []
        )
        return ModeRegistryTestSupport.makePort(modeProfileConfiguration: config)
    }

    @Test("dispatch resolution uses mode fallback when mode query resolves empty")
    func dispatchResolutionUsesModeFallback() async throws {
        let primaryEntry = makeEntry(slug: "primary-model")
        let fallbackEntry = makeEntry(slug: "fallback-model")
        let allByID = [primaryEntry.id: primaryEntry, fallbackEntry.id: fallbackEntry]
        let rankedProvider: @Sendable (ModelReference) async -> [ModelRegistryEntry] = { ref in
            guard case .query(let query) = ref else { return [] }
            switch query.preferredUseClass {
            case "primary-query":
                return []
            case "fallback-query":
                return [fallbackEntry]
            default:
                return []
            }
        }
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            registryEntryProvider: { id in allByID[id] },
            rankedRegistryEntriesProvider: rankedProvider,
            modeRegistry: modeRegistryWithFallbackProfile()
        )
        try await manager.createConversation(
            with: primaryEntry.toModel(),
            userSystemPrompt: "sys",
            interactionMode: .chat,
            modeProfileID: "dispatch-mode"
        )

        let resolved = try #require(await manager.testing_resolveDispatchPrimaryModelForCurrentConversation())
        #expect(resolved.modelID == fallbackEntry.id)
        #expect(resolved.usedModeFallback)
    }

    @Test("dispatch resolution keeps selected model when mode query is absent")
    func dispatchResolutionNoModeQueryKeepsSelectedModel() async throws {
        let selectedEntry = makeEntry(slug: "selected-model")
        let allByID = [selectedEntry.id: selectedEntry]
        let manager = HarnessRuntimeSession(
            container: try makeContainer(),
            registryEntryProvider: { id in allByID[id] },
            rankedRegistryEntriesProvider: { _ in [] },
            modeRegistry: ModeRegistryTestSupport.makePort()
        )
        try await manager.createConversation(
            with: selectedEntry.toModel(),
            userSystemPrompt: "sys",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )

        let resolved = try #require(await manager.testing_resolveDispatchPrimaryModelForCurrentConversation())
        #expect(resolved.modelID == selectedEntry.id)
        #expect(resolved.usedModeFallback == false)
    }
}
