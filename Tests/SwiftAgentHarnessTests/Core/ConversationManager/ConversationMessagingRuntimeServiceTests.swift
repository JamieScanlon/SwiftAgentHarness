import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationMessagingRuntimeService", .serialized)
struct ConversationMessagingRuntimeServiceTests {

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

    @Test("update(conversation:) syncs registry and session projection for selected conversation")
    func updateConversationSyncsRegistry() async throws {
        let container = try makeContainer()
        let session = makeSession(container: container)
        let model = Model(
            protocol: .openAIAPI,
            modelName: "cmrs:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
        try await session.createConversation(with: model, userSystemPrompt: "sys", topic: nil, description: nil)
        let conversation = try #require(await session.currentConversation())
        await session.testing_setCurrentConversationID(conversation.id)

        var updated = conversation
        updated.state = .generating
        updated.agenticPhase = .executingTools
        updated.currentRunID = UUID()
        await session.conversationMessagingRuntimeService.update(conversation: updated)

        let registryRow = try #require(await session.testing_modelConversation(conversationID: conversation.id))
        #expect(registryRow.state == .generating)
        #expect(registryRow.agenticPhase == .executingTools)
        #expect(registryRow.currentRunID == updated.currentRunID)
        let projected = try await session.listCurrentMessages()
        #expect(projected.count == registryRow.messages.count)
    }
}
