import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Control input boundary", .serialized)
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

    private static func withHost(
        _ body: (EmbeddedHarnessHost, Model) async throws -> Void
    ) async throws {
        let container = try Self.makeContainer()
        let model = Self.makeModel()
        let host = try await EmbeddedHarnessHost.makeForTesting(container: container, model: model)
        do {
            try await body(host, model)
        } catch {
            try await host.shutdown()
            throw error
        }
        try await host.shutdown()
    }

    @Test("Directive-only /think high persists thinking config and acknowledges")
    func directiveOnlyPersistsThinking() async throws {
        try await Self.withHost { host, model in
            let conversationID = try await host.apiClient.createConversation(
                session: host.defaultSession,
                request: EmbeddedCreateConversationRequest(modelRef: model.id.uuidString, userSystemPrompt: "sys")
            )

            _ = try await host.apiClient.sendMessage(
                session: host.defaultSession,
                conversationID: conversationID,
                request: EmbeddedSendMessageRequest(message: "/think high")
            )

            let conversation = try #require(await host.runtimeSession.modelConversation(id: conversationID))
            #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == ThinkingConfig.level(.high, budgetTokens: nil))

            let messages = try await host.runtimeSession.listMessages(conversationID: conversationID)
            #expect(!messages.contains(where: { $0.role == .user && $0.content.contains("/think") }))
            #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("Thinking set to high") }))
        }
    }

    @Test("Standalone /help renders catalog output without user slash text")
    func standaloneHelp() async throws {
        try await Self.withHost { host, model in
            let conversationID = try await host.apiClient.createConversation(
                session: host.defaultSession,
                request: EmbeddedCreateConversationRequest(modelRef: model.id.uuidString, userSystemPrompt: "sys")
            )

            _ = try await host.apiClient.sendMessage(
                session: host.defaultSession,
                conversationID: conversationID,
                request: EmbeddedSendMessageRequest(message: "/help")
            )

            let messages = try await host.runtimeSession.listMessages(conversationID: conversationID)
            #expect(!messages.contains(where: { $0.role == .user && $0.content == "/help" }))
            #expect(messages.contains(where: { $0.role == .assistant && $0.content.contains("Available commands:") }))
        }
    }
}
