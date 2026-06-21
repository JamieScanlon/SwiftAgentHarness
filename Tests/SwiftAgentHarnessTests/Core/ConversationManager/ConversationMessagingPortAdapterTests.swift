import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationMessagingPortAdapter")
struct ConversationMessagingPortAdapterTests {

    @Test("unbound adapter throws failedToInitialize on saveMessageToCache")
    func unboundSaveThrows() async {
        let adapter = ConversationMessagingPortAdapter.unbound
        let message = Message(id: UUID(), role: .user, content: "hello")
        await #expect(throws: ConversationServiceError.self) {
            _ = try await adapter.saveMessageToCache(
                message,
                for: UUID(),
                expectedPreviousTailHarnessMessageID: nil,
                transcriptRunID: nil
            )
        }
    }

    @Test("factory-bound adapter forwards update to ConversationMessagingRuntimeService")
    func factoryBoundAdapterForwardsUpdate() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let session = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let model = Model(
            protocol: .openAIAPI,
            modelName: "port-adapter:test",
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
        await (await session.services).conversationMessagingRuntimeService.update(conversation: updated)

        let registryRow = try #require(await session.testing_modelConversation(conversationID: conversation.id))
        #expect(registryRow.state == .generating)
    }
}
