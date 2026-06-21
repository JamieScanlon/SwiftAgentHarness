import Foundation
import Testing
@testable import SwiftAgentHarness
import SwiftAgentKit

@Suite("Harness registry hard delete")
struct HarnessRegistryDeletionTests {
    @Test("deleteConversation removes local catalog row and transcript")
    func localHardDeleteDoesNotRehydrate() throws {
        let fixture = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "hard-delete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = HarnessConversationTestFixtures.makeTestModel(name: "delete-me")
        let cm = fixture.stack.conversationManager
        let created = try cm.createConversation(with: model, userSystemPrompt: "sys", topic: "gone")
        let id = created.id
        #expect(try fixture.local.catalogConversation(id: id) != nil)

        try cm.deleteConversation(conversationID: id)
        #expect(cm.listConversationInfo().isEmpty)
        #expect(try fixture.local.catalogConversation(id: id) == nil)

        try HarnessConversationTestFixtures.resetRegistryFromCatalog(manager: cm, availableModels: [model])
        #expect(cm.listConversationInfo().isEmpty)
    }
}
