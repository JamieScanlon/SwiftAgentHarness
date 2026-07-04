import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Control input boundary")
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
