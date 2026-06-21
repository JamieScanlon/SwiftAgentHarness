import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentCompletionRuntimeService")
struct SubAgentCompletionRuntimeServiceTests {
    @Test("resolvePendingCompletionConversationID finds tool call in persisted conversation")
    func resolvePendingCompletionByToolCallID() async throws {
        let schema = HarnessPersistenceSchema.latest
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "completion-resolve-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI
        )
        try await host.createConversation(with: model, userSystemPrompt: "completion-resolve")
        let conversationID = try #require(await host.currentConversationID)
        let toolCallID = "tool-call-\(UUID().uuidString)"
        _ = try await host.saveMessageToCache(
            Message(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                toolCalls: [ToolCall(name: "delegate_test", arguments: .object([:]), id: toolCallID)]
            ),
            for: conversationID
        )

        let resolved = await host.subAgentCompletionRuntimeService.resolvePendingCompletionConversationID(
            toolCallID: toolCallID
        )
        #expect(resolved == conversationID)
    }
}
