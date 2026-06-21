import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Agent Runtime — concurrency", .serialized)
struct AgentRuntimeConcurrencyTests {
    @Test("Two HarnessRuntimeSession actors with same store keep independent currentConversationID under concurrent select")
    func twoManagersIsolateSelection() async throws {
        let (stack, local, root) = try HarnessConversationTestFixtures.makeLocalPersistenceStack(label: "concurrency-two-hosts")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = HarnessConversationTestFixtures.makeTestModel(name: "t")
        let seedHost = HarnessRuntimeSession(
            container: stack.modelContainer,
            harnessSessionPersistenceOverride: local
        )
        let (id1, id2) = try await HarnessConversationTestFixtures.seedTwoDistinctRegistryConversations(
            host: seedHost,
            model: model,
            userContentA: "a",
            userContentB: "b",
            systemPromptA: "s",
            systemPromptB: "s2"
        )

        let m1 = HarnessRuntimeSession(
            container: stack.modelContainer,
            harnessSessionPersistenceOverride: local
        )
        let m2 = HarnessRuntimeSession(
            container: stack.modelContainer,
            harnessSessionPersistenceOverride: local
        )
        try await m1.resetConversationsFromCatalog(availableModels: [model])
        try await m2.resetConversationsFromCatalog(availableModels: [model])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try await m1.selectConversation(conversationID: id1)
                }
                group.addTask {
                    try await m2.selectConversation(conversationID: id2)
                }
            }
            for try await _ in group {}
        }

        #expect(await m1.currentConversationID == id1)
        #expect(await m2.currentConversationID == id2)
    }
}
