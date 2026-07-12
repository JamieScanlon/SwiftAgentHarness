import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Slash command embedded loopback", .serialized)
struct SlashCommandEmbeddedLoopbackTests {
  @Test("/think directive persists via embedded PATCH loopback")
  func thinkDirectiveUsesPatchLoopback() async throws {
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Model(
      protocol: .openAIAPI,
      modelName: "slash-loopback:test",
      serverURL: URL(string: "http://localhost:1234")!,
      capabilities: [.completion],
      modelProtocol: .openAIAPI
    )
    let host = try await EmbeddedHarnessHost.makeForTesting(container: container, model: model)
    do {
      let conversationID = try await host.apiClient.createConversation(
        session: host.defaultSession,
        request: EmbeddedCreateConversationRequest(modelRef: model.id.uuidString, userSystemPrompt: "sys")
      )

      _ = try await host.apiClient.sendMessage(
        session: host.defaultSession,
        conversationID: conversationID,
        request: EmbeddedSendMessageRequest(message: "/think medium")
      )

      let conversation = try #require(await host.runtimeSession.modelConversation(id: conversationID))
      #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == ThinkingConfig.level(.medium, budgetTokens: nil))
    } catch {
      try await host.shutdown()
      throw error
    }
    try await host.shutdown()
  }
}
