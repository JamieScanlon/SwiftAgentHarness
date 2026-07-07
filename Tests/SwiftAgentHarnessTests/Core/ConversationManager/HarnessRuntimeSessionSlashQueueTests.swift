import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private enum SlashQueueTestSupport {
    static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "slash-queue:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }
}

@Suite("HarnessRuntimeSession slash command queue when busy", .serialized)
struct HarnessRuntimeSessionSlashQueueTests {

    @Test("/compact while generating is queued then runs after drain")
    func compactQueuedThenDrained() async throws {
        let container = try SlashQueueTestSupport.makeContainer()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        let model = SlashQueueTestSupport.makeModel()
        try await manager.createConversation(with: model, userSystemPrompt: "sys")
        let cid = try #require(await manager.currentConversationID)

        await manager.testing_setSlashDispatchConversationState(
            conversationID: cid,
            state: .generating,
            agenticPhase: .started
        )

        _ = try await manager.sendMessageAndStreamResponse("/compact q", images: [], conversationID: cid)

        let midQueued = try await manager.listCurrentMessages()
        #expect(midQueued.contains { $0.role == .assistant && $0.content.contains("Queued:") })
        #expect(!midQueued.contains { $0.role == .assistant && $0.content.contains("Conversation compacted:") })

        await manager.testing_setSlashDispatchConversationState(
            conversationID: cid,
            state: .idle,
            agenticPhase: .idle
        )
        await manager.slashCommandDispatchService.drainPendingSlashCommandsIfNeeded(conversationID: cid)

        let after = try await manager.listCurrentMessages()
        #expect(after.contains { $0.role == .assistant && $0.content.contains("Conversation compacted:") })
    }
}
