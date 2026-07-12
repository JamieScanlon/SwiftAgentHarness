import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("EmbeddedHarnessHost integration", .serialized)
struct EmbeddedHarnessHostIntegrationTests {
  @Test("host create and directive send share runtime session")
  func hostCreateAndDirectiveSend() async throws {
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Model(
      protocol: .openAIAPI,
      modelName: "embedded-host:test",
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
        request: EmbeddedSendMessageRequest(message: "/think high")
      )

      let conversation = try #require(await host.runtimeSession.modelConversation(id: conversationID))
      #expect(conversation.routingPrefs?.modelOptions?.thinkingConfig == ThinkingConfig.level(.high, budgetTokens: nil))
    } catch {
      try await host.shutdown()
      throw error
    }
    try await host.shutdown()
  }
}
