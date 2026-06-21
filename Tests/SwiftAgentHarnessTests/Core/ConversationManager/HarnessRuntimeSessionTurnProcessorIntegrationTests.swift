import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSession turn processor integration")
struct HarnessRuntimeSessionTurnProcessorIntegrationTests {
    private func makeModel(id: UUID) -> Model {
        Model(
            id: id,
            protocol: .openAIAPI,
            modelName: "test-model",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("resetConversationsFromCatalog backfills persisted turns for agent mode")
    func resetBackfillsTurnsForAgent() async throws {
        let fixture = try HarnessConversationTestFixtures.makeHarnessRuntimeHost(label: "turn-processor-agent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let modelID = UUID()
        let model = makeModel(id: modelID)
        let base = Date().addingTimeInterval(-100)
        try await fixture.host.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: nil,
            description: nil,
            metadata: nil,
            interactionMode: .agent
        )
        let conversationID = try #require(await fixture.host.currentConversationID)
        try await fixture.host.selectConversation(conversationID: conversationID)
        await fixture.host.testing_applyOrchestratorMessages([
            Message(id: UUID(), role: .user, content: "u1", timestamp: base.addingTimeInterval(1), toolCalls: []),
            Message(id: UUID(), role: .assistant, content: "a1", timestamp: base.addingTimeInterval(2), toolCalls: []),
        ])
        try await fixture.host.resetConversationsFromCatalog(availableModels: [model])

        let conversations = await await makeSplitConversationAdapter(runtimeSession: fixture.host).apiListConversationInfo()
        #expect(conversations.first?.turns.count == 2)
    }
}
