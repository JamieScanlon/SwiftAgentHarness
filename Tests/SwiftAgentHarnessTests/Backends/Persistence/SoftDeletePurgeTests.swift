import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("Soft delete retention purge")
struct SoftDeletePurgeTests {
    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "purge-test",
            serverURL: URL(string: "http://127.0.0.1:1")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    @Test("purgeSoftDeletedPastRetention hard-deletes stale soft-deleted rows")
    func purgeRemovesExpiredSoftDeletes() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let model = makeModel()
        let chat = HarnessRuntimeSession(container: container, logger: nil)
        let conversationAPI = await makeSplitConversationAdapter(runtimeSession: chat)
        try await chat.createConversation(with: model, userSystemPrompt: "sys")
        let id = try #require(await chat.currentConversationID)
        try await chat.deleteConversation(conversationID: id, hard: false)

        let old = try #require(Calendar.current.date(byAdding: .day, value: -10, to: Date()))
        await chat.testing_setRegistryConversationUpdatedAt(conversationID: id, updatedAt: old)

        let purged = try await chat.purgeSoftDeletedPastRetention(retentionDays: 5)
        #expect(purged == 1)
        let gone = await conversationAPI.apiGetConversation(id: id)
        #expect(gone == nil)
    }
}
