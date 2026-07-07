import EasyJSON
import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence (SwiftData projection)")
struct SessionPersistenceHarnessTests {

    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "session-persist-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test func catalogAndTranscriptReadThroughConversationManager() throws {
        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let model = makeModel()
        let conversation = try manager.createConversation(
            with: model,
            userSystemPrompt: "You are a test assistant.",
            topic: "T1",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: InteractionMode.chat
        )
        let persistence = manager.harnessSessionPersistence
        let catalog = try persistence.listCatalogConversations()
        #expect(catalog.count == 1)
        #expect(catalog[0].id == conversation.id)
        #expect(catalog[0].topic == "T1")
        #expect(catalog[0].messageCount == conversation.messages.count)

        let entries = try persistence.readTranscriptEntries(conversationID: conversation.id, request: .full)
        #expect(entries.count == conversation.messages.count)
        #expect(entries.first?.sequence == 1)
        #expect(entries.first?.type == .system)

        let lock = try persistence.acquireTranscriptWriteLock(conversationID: conversation.id, allowReentrant: false)
        #expect(lock.conversationID == conversation.id)
        lock.unlock()
    }
}
