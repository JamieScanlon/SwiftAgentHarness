import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Agent-build orchestrator harness options apply only when the mode profile requests them.
@Suite("HarnessRuntimeSession agent orchestrator history window gating", .serialized)
struct HarnessRuntimeSessionAgentOrchestratorHistoryWindowGatingTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "gating:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
    }

    @Test("chat mode skips agent-build orchestrator harness options")
    func chatModeSkipsAgentBuildHarness() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .chat,
            modeProfileID: InteractionMode.chat.rawValue
        )
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(for: conv)
        #expect(options.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable != true)
    }

    @Test("agent mode applies agent-build orchestrator harness options")
    func agentModeAppliesAgentBuildHarness() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .agent,
            modeProfileID: InteractionMode.agent.rawValue
        )
        let harness = AgentHarnessConfiguration.loadFromPromptConfigBundle()
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conv,
            effectiveToolEntries: [
                ToolRegistryEntry(
                    definition: ToolDefinition(name: "get_plan", description: "plan", parameters: [], type: .function),
                    source: .local
                ),
            ]
        )
        #expect(options.toolInvocationPolicy == harness.agentBuildToolInvocationPolicy)
        #expect(
            options.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable
                == harness.rejectAssistantTurnWithNoToolCallsWhenToolsAvailable
        )
        #expect(options.maxAgenticStepsPerUpdate == nil)
    }

    @Test("plan mode does not apply agent-build tool invocation policy")
    func planModeSkipsAgentBuildToolPolicy() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let conv = ModelConversation(
            id: UUID(),
            model: makeModel(),
            systemPrompt: "s",
            interactionMode: .plan,
            modeProfileID: InteractionMode.plan.rawValue
        )
        let harness = AgentHarnessConfiguration.default
        let options = await runtimeSession.orchestratorRuntimeService.orchestratorInvocationOptions(
            for: conv,
            effectiveToolEntries: [
                ToolRegistryEntry(
                    definition: ToolDefinition(name: "get_plan", description: "plan", parameters: [], type: .function),
                    source: .local
                ),
            ]
        )
        #expect(options.toolInvocationPolicy != harness.agentBuildToolInvocationPolicy)
    }
}
