import EasyJSON
import Foundation
import SwiftData
import SwiftAgentKit
import SwiftAgentKitOrchestrator
import SwiftAgentKitMCP
import Testing
@testable import SwiftAgentHarness

private extension MCPManager {
    func testing_markInitialized() {
        state = .initialized
    }
}

@Suite("OrchestratorRuntimeService", .serialized)
struct OrchestratorRuntimeServiceTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
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

    @Test("setupOrchestrator warms orchestrator for explicit conversation")
    func setupOrchestratorBindsOrchestrator() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())

        await session.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)

        #expect(await session.sessionOrchestrator() != nil)
        #expect(await session.sessionOrchestratorConversationID() == conversation.id)
    }

    @Test("invalidateOrchestrator clears orchestrator binding")
    func invalidateOrchestratorClearsBinding() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = makeModel()
        try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
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
        try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())
        await session.orchestratorRuntimeService.setupOrchestrator(with: model, activeConversation: conversation)
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
        try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())

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
