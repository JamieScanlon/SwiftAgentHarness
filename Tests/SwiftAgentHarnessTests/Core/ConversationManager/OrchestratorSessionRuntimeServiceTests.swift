import Foundation
import SwiftAgentKit
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("OrchestratorSessionRuntimeService")
struct OrchestratorSessionRuntimeServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeSession(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    @Test("resolvedModeProfile uses mode registry fallback")
    func resolvedModeProfileUsesRegistry() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let conv = ModelConversation(
            id: UUID(),
            model: Model(
                protocol: .openAIAPI,
                modelName: "test",
                serverURL: URL(string: "http://localhost:1")!,
                capabilities: [.completion],
                modelProtocol: .openAIAPI
            ),
            systemPrompt: "s",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let profile = await session.orchestratorSessionRuntimeService.resolvedModeProfile(for: conv)
        #expect(profile.id == InteractionMode.chat.rawValue)
    }

    @Test("unbound orchestrator port returns empty system prompt metadata")
    func unboundPortMetadataDefaults() async {
        let adapter = OrchestratorSessionPortAdapter.makeUnbound()
        let metadata = await adapter.systemPromptMetadata(for: nil, resolvedProfile: ResolvedModeProfile.builtIn(for: .chat))
        #expect(metadata.isEmpty)
    }

    @Test("default session mode policy context uses chat mode")
    func defaultSessionModePolicyContext() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let ctx = await session.orchestratorSessionRuntimeService.defaultSessionModePolicyContext()
        #expect(ctx.interactionMode == .chat)
    }
}
