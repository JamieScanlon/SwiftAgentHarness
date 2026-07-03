import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Conversation runtime lifecycle phase projection")
struct ConversationRuntimeLifecyclePhaseProjectionTests {
    @Test("model/tool lifecycle events project orchestration phases")
    func runtimeLifecycleProjectsInFlightPhases() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "phase-projection", interactionMode: .chat)
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(
            RuntimeLifecycleEventPayload(
                name: .modelCallStarted,
                conversationID: conversationID,
                runID: runID
            )
        )
        let modelConversation = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(modelConversation.agenticPhase == .llmCall)
        #expect(modelConversation.llmRequestPhase == .generating)
        #expect(modelConversation.currentRunID == runID)

        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(
            RuntimeLifecycleEventPayload(
                name: .toolCallStarted,
                conversationID: conversationID,
                runID: runID
            )
        )
        let toolConversation = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(toolConversation.agenticPhase == .executingTools)
        #expect(toolConversation.llmRequestPhase == .active)
        #expect(toolConversation.currentRunID == runID)
    }

    @Test("terminal lifecycle events clear in-flight orchestration state")
    func runtimeLifecycleProjectsTerminalIdleState() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "phase-terminal", interactionMode: .chat)
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(
            RuntimeLifecycleEventPayload(
                name: .modelCallStarted,
                conversationID: conversationID,
                runID: runID
            )
        )
        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(
            RuntimeLifecycleEventPayload(
                name: .turnCompleted,
                conversationID: conversationID,
                runID: runID
            )
        )

        let finalConversation = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(finalConversation.agenticPhase == .idle)
        #expect(finalConversation.llmRequestPhase == .idle)
        #expect(finalConversation.currentRunID == nil)
    }

    @Test("runtime lifecycle projection preserves existing transcript messages")
    func runtimeLifecycleProjectionPreservesTranscript() async throws {
        let manager = HarnessRuntimeSession(container: try makeContainer())
        try await manager.createConversation(with: makeModel(), userSystemPrompt: "phase-transcript", interactionMode: .chat)
        let conversationID = try #require(await manager.currentConversationID)
        let runID = UUID()

        await manager.testing_applyOrchestratorMessages([
            Message(
                id: UUID(),
                role: .assistant,
                content: "persist-me",
                timestamp: Date(),
                toolCalls: []
            ),
        ])
        let before = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(before.messages.contains(where: { $0.role == .assistant && $0.content == "persist-me" }))

        await manager.runtimeLifecyclePublicationService.publishRuntimeLifecycleWithFanout(
            RuntimeLifecycleEventPayload(
                name: .modelCallStarted,
                conversationID: conversationID,
                runID: runID
            )
        )

        let after = try #require(await manager.testing_modelConversation(conversationID: conversationID))
        #expect(after.messages.contains(where: { $0.role == .assistant && $0.content == "persist-me" }))
        #expect(after.messages.count == before.messages.count)
        #expect(after.currentRunID == runID)
    }

    private func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    private func makeModel() -> Model {
        Model(
            id: UUID(),
            protocol: .ollama,
            modelName: "phase-projection-model",
            serverURL: URL(string: "http://localhost:11434")!,
            capabilities: [.completion, .tools],
            modelProtocol: .ollama
        )
    }
}
