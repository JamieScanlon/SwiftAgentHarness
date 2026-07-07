import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftAgentKitMCP
import Testing
import SwiftAgentHarnessProviders
@testable import SwiftAgentHarness

private extension MCPManager {
    func testing_markInitialized() {
        state = .initialized
    }
}

@Suite("OrchestratorRuntimeService", .serialized)
struct OrchestratorRuntimeServiceTests {

    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel(name: String = "ors:test") -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: name,
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
    }

    private func makeSession(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    private func prepareConversation(
        session: HarnessRuntimeSession,
        model: Model
    ) async throws -> ModelConversation {
        ProviderTestManifestSupport.prepareRegistry()
        _ = try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())
        await session.testing_setCurrentConversationID(conversation.id)
        return conversation
    }

    private func warmOrchestrator(
        session: HarnessRuntimeSession,
        model: Model,
        conversation: ModelConversation
    ) async throws {
        await session.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
        if await session.sessionOrchestrator() == nil {
            await session.testing_ensureOrchestratorPoolEntry(model: model, conversation: conversation)
        }
        try #require(await session.sessionOrchestrator() != nil, "Orchestrator warm-up failed")
    }

    @Test("setupOrchestrator warms orchestrator for explicit conversation")
    func setupOrchestratorBindsOrchestrator() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        let conversation = try await prepareConversation(session: session, model: model)

        try await warmOrchestrator(session: session, model: model, conversation: conversation)

        #expect(await session.sessionOrchestrator() != nil)
        #expect(await session.sessionOrchestratorConversationID() == conversation.id)
    }

    @Test("invalidateOrchestrator clears orchestrator binding")
    func invalidateOrchestratorClearsBinding() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        let conversation = try await prepareConversation(session: session, model: model)
        try await warmOrchestrator(session: session, model: model, conversation: conversation)
        #expect(await session.sessionOrchestrator() != nil)

        await session.orchestratorRuntimeService.invalidateOrchestrator(for: conversation.id)

        #expect(await session.sessionOrchestrator() == nil)
        #expect(await session.sessionOrchestratorConversationID() == conversation.id)
    }

    @Test("allToolRegistryEntriesForOrchestration includes built-in conversation tools after setup")
    func toolRegistryIncludesBuiltInsAfterSetup() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        let conversation = try await prepareConversation(session: session, model: model)
        try await warmOrchestrator(session: session, model: model, conversation: conversation)
        let orchestrator = try #require(await session.sessionOrchestrator())

        let entries = await session.orchestratorRuntimeService.allToolRegistryEntriesForOrchestration(orchestrator: orchestrator)
        let names = Set(entries.map(\.name))
        #expect(names.contains("list_conversations"))
    }

    @Test("orchestratorAdditionalParameters includes thinking config metadata")
    func additionalParametersIncludeThinkingConfig() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        let conversation = try await prepareConversation(session: session, model: model)

        let params = await session.orchestratorRuntimeService.orchestratorAdditionalParameters(for: conversation)
        guard case .object(let object) = params else {
            Issue.record("Expected object additional parameters")
            return
        }
        #expect(object["thinkingConfig"] != nil)
    }

    @Test("orchestratorInvocationOptions applies agent-build harness for agent mode")
    func invocationOptionsAgentBuildHarness() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue
        )
        let options = await session.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.toolInvocationPolicy == AgentHarnessConfiguration.default.agentBuildToolInvocationPolicy)
    }

    @Test("shutdownToolRuntimes completes without orchestrator")
    func shutdownWithoutOrchestrator() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        await session.orchestratorRuntimeService.shutdownToolRuntimes(existingOrchestrator: nil)
    }

    @Test("releasePooledOrchestrator leaves shared MCP manager initialized")
    func releasePooledOrchestratorPreservesSharedManagers() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let sharedMCP = MCPManager()
        await sharedMCP.testing_markInitialized()

        let config = OrchestratorConfig(
            streamingEnabled: true,
            mcpEnabled: true,
            a2aIntegration: .disabled,
            acpIntegration: .disabled
        )
        let orchestrator = SwiftAgentKitOrchestrator(
            llm: StubTurnLoopLLM(),
            config: config,
            mcpManager: sharedMCP
        )

        await session.orchestratorRuntimeService.releasePooledOrchestrator(orchestrator)
        #expect(await sharedMCP.state == .initialized)

        await session.orchestratorRuntimeService.shutdownToolRuntimes(existingOrchestrator: orchestrator)
        #expect(await sharedMCP.state == .notReady)
    }
}
