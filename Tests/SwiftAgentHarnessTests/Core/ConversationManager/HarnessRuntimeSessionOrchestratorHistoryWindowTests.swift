import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

/// Agent-build mode relies on context transforms to trim history before orchestrator updates.
@Suite("HarnessRuntimeSession orchestrator history window", .serialized)
struct HarnessRuntimeSessionOrchestratorHistoryWindowTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "history-window:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
    }

    @Test("agent mode enables context transform gating by default")
    func agentModeEnablesContextTransformGating() async throws {
        let config = ConversationTransformConfiguration.default
        #expect(
            ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .agent,
                contextCompactionLevel: nil,
                transformConfiguration: config
            )
        )
        #expect(
            ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .chat,
                contextCompactionLevel: nil,
                transformConfiguration: config
            )
        )
    }

    @Test("compaction level off disables context transform for agent mode")
    func compactionOffDisablesAgentContextTransform() async throws {
        let config = ConversationTransformConfiguration.default
        #expect(
            !ContextEngineProjectionPolicyBuilder.shouldEnableContextTransform(
                interactionMode: .agent,
                contextCompactionLevel: "off",
                transformConfiguration: config
            )
        )
    }

    @Test("transformedContextMessages returns projected messages for agent conversations")
    func transformedContextMessagesForAgentConversation() async throws {
        let container = try makeContainer()
        let runtimeSession = HarnessRuntimeSession(container: container)
        let model = makeModel()
        try await runtimeSession.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        let conversation = try #require(await runtimeSession.currentConversation())
        let transformed = await runtimeSession.contextProjectionService.transformedContextMessages(
            from: conversation.messages,
            conversation: conversation,
            phase: .initial
        )
        #expect(!transformed.isEmpty)
        #expect(transformed.contains(where: { $0.role == .system }))
    }
}
