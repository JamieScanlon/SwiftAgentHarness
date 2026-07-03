import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Control input boundary integration", .serialized)
struct ControlInputBoundaryIntegrationTests {
    private static func makeContainer() throws -> ModelContainer {
                return try HarnessTestModelContainer.makeInMemory()
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

    @Test("Directive-only /think high persists thinking config and acknowledges")
    func directiveOnlyPersistsThinking() async throws {
        let container = try Self.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        _ = try await manager.sendMessageAndStreamResponse("/think high", images: [], conversationID: conversationID)

        let conversation = try #require(await manager.modelConversation(id: conversationID))
        #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == ThinkingConfig.level(.high, budgetTokens: nil))

        let messages = try await manager.listCurrentMessages()
        #expect(!messages.contains(where: { $0.role == .user && $0.content.contains("/think") }))
        #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("Thinking set to high") }))
    }

    @Test("Inline /think high returns stripped prose and turn override without persisting")
    func inlineHintBoundaryOutcome() async throws {
        let container = try Self.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
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

    @Test("Standalone /help renders catalog output without user slash text")
    func standaloneHelp() async throws {
        let container = try Self.makeContainer()
        let manager = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        try await manager.createConversation(with: Self.makeModel(), userSystemPrompt: "sys")
        let conversationID = try #require(await manager.currentConversationID)

        _ = try await manager.sendMessageAndStreamResponse("/help", images: [], conversationID: conversationID)

        let messages = try await manager.listCurrentMessages()
        #expect(!messages.contains(where: { $0.role == .user && $0.content == "/help" }))
        #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("Available commands:") }))
    }
}
