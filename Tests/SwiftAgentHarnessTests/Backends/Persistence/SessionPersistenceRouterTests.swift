import EasyJSON
import Foundation
@testable import SwiftAgentHarness
import SwiftAgentKit
import SwiftData
import Testing

@Suite("Harness session persistence (local provisioning)")
struct SessionPersistenceRouterTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "router-test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test func createConversationWritesTranscriptToLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let local = try LocalHarnessSessionPersistence(root: root)
        manager.setHarnessSessionPersistenceOverride(local)
        let model = makeModel()
        let conversation = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "R1",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )

        let entries = try local.readTranscriptEntries(conversationID: conversation.id, request: .full)
        #expect(entries.count == conversation.messages.count)
        #expect(entries.first?.type == SessionTranscriptEntryType.system)
    }

    @Test func provisionNewConversationUsesHarnessWhenAttached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let local = try LocalHarnessSessionPersistence(root: root)
        manager.setHarnessSessionPersistenceOverride(local)

        let model = makeModel()
        let conversation = try manager.createConversation(
            with: model,
            userSystemPrompt: "provisioned",
            topic: nil,
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )

        let entries = try local.readTranscriptEntries(conversationID: conversation.id, request: .full)
        #expect(entries.count == 1)
        #expect(entries.first?.type == .system)
    }

    @Test func createConversationRoutesThroughSessionBackendForInMemoryWhenEnabled() throws {
        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        manager.setHarnessSessionPersistenceOverride(InMemoryHarnessSessionPersistence())
        let model = makeModel()

        let first = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "Shared",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )
        let second = try manager.createConversation(
            with: model,
            userSystemPrompt: "sys",
            topic: "Shared",
            description: nil as String?,
            metadata: nil as JSON?,
            interactionMode: .chat
        )

        #expect(first.id != second.id)
        #expect(first.topic == "Shared")
        #expect(second.topic != "Shared")
        #expect(second.topic?.hasPrefix("Shared ") == true)
    }

    @Test func managerListRouteUsesSessionBackendListConversations() throws {
        let container = try makeContainer()
        let manager = ConversationManager(container: container, logger: nil)
        let mem = InMemoryHarnessSessionPersistence()
        manager.setHarnessSessionPersistenceOverride(mem)

        var record = SessionCatalogRecord(
            id: UUID(),
            topic: "listed",
            description: nil,
            messageCount: 0,
            updatedAt: Date(),
            createdAt: Date(),
            modelName: "m",
            interactionModeRaw: InteractionMode.chat.rawValue,
        )
        record.source = "cli"
        try mem.bootstrapEmptyConversation(record)

        let page = try manager.listSessionBackendConversations(
            filter: SessionConversationListFilter(
                agentId: SessionPersistenceLayout.defaultAgentId,
                source: "cli",
                cwd: nil,
                lifecycleState: nil,
                since: nil
            ),
            limit: 10,
            cursor: nil
        )
        #expect(page.records.count == 1)
        #expect(page.records[0].id == record.id)
    }
}
