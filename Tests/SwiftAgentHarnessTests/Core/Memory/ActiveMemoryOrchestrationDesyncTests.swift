import Foundation
import SwiftData
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Active memory orchestration desync", .serialized)
struct ActiveMemoryOrchestrationDesyncTests {
    private func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "parent-qwen",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion, .tools],
            modelProtocol: .openAIAPI,
            maxContextLength: 8_192
        )
    }

    @Test("child quota failure does not attach termination detail to parent snapshot")
    func childFailureDoesNotPolluteParentSnapshot() async throws {
        let container = try makeContainer()
        let session = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let parentModel = makeModel()
        try await session.createConversation(with: parentModel, userSystemPrompt: "parent", topic: nil, description: nil)
        let parent = try #require(await session.currentConversation())
        let parentRunID = UUID()
        await session.agentRuntimeSessionService.testing_setActiveStreamingRun(
            conversationID: parent.id,
            runID: parentRunID
        )
        defer {
            Task { await session.agentRuntimeSessionService.testing_setActiveStreamingRun(conversationID: nil, runID: nil) }
        }

        let childID = try await session.persistenceDomain.createIsolatedSubAgent(
            parentConversationID: parent.id,
            selectedModel: MemorySubAgentSpawnAdapter.activeMemoryModel(from: .default),
            userSystemPrompt: ActiveMemoryPreReplyPrompts.systemPrompt(),
            topic: "memory-active-recall",
            description: nil,
            metadata: nil,
            interactionMode: .chat,
            modeProfileID: "memory-active-recall"
        ).id
        let childRunID = UUID()
        await session.agentRuntimeSessionService.setPendingTerminalReason(
            ConversationRunTerminalReason(category: .failure, detail: "Quota exceeded"),
            conversationID: childID,
            runID: childRunID
        )

        await session.testing_setConversationRuntimeState(
            conversationID: parent.id,
            state: .generating,
            agenticPhase: .started,
            llmRequestPhase: .queued,
            currentRunID: parentRunID
        )

        let snapshot = try #require(await session.snapshotOrchestrationState(for: parent.id))
        #expect(snapshot.harness?.terminationDetail != "Quota exceeded")
    }
}
