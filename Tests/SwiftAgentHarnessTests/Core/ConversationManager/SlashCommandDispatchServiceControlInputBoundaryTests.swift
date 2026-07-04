import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("SlashCommandDispatchService control input boundary")
struct SlashCommandDispatchServiceControlInputBoundaryTests {
    private static func makeContainer() throws -> ModelContainer {
        try HarnessTestModelContainer.makeInMemory()
    }

    private static func makeModel() -> Model {
        Model(
            protocol: .openAIAPI,
            modelName: "control-input:test",
            serverURL: URL(string: "http://localhost:1234")!,
            capabilities: [.completion],
            modelProtocol: .openAIAPI
        )
    }

    private static func makeManager(container: ModelContainer) -> HarnessRuntimeSession {
        HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
    }

    @Test("Inline /think high returns stripped prose and turn override without persisting")
    func inlineHintBoundaryOutcome() async throws {
        let container = try Self.makeContainer()
        let manager = Self.makeManager(container: container)
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        let outcome = try await manager.slashCommandDispatchService.processControlInputBoundary(
            text: "/think high summarize the logs",
            conversationID: conversationID,
            trustClass: TrustPolicyClass.trusted,
            senderLabel: nil as String?
        )

        guard case let .continueTurn(modelText, patch, preTurnAck) = outcome else {
            Issue.record("Expected continueTurn outcome")
            return
        }
        #expect(modelText == "summarize the logs")
        #expect(patch.turnThinkingOverride == ThinkingConfig.level(.high, budgetTokens: nil))
        #expect(preTurnAck == nil)

        let conversation = try #require(await manager.modelConversation(id: conversationID))
        #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == nil)
    }
}
