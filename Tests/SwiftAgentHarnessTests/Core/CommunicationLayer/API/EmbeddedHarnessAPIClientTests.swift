import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("EmbeddedHarnessAPIClient", .serialized)
struct EmbeddedHarnessAPIClientTests {
  private static func makeModel() -> Model {
    Model(
      protocol: .openAIAPI,
      modelName: "embedded-client:test",
      serverURL: URL(string: "http://localhost:1234")!,
      capabilities: [.completion],
      modelProtocol: .openAIAPI
    )
  }

  private static func withHost(
    container: ModelContainer,
    model: Model,
    tenancyPolicy: TenancyPolicySettings = .disabled,
    _ body: (EmbeddedHarnessHost) async throws -> Void
  ) async throws {
    let host = try await EmbeddedHarnessHost.makeForTesting(
      container: container,
      model: model,
      tenancyPolicy: tenancyPolicy
    )
    do {
      try await body(host)
    } catch {
      try await host.shutdown()
      throw error
    }
    try await host.shutdown()
  }

  @Test("embedded loopback creates conversation and patches metadata")
  func createAndPatch() async throws {
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Self.makeModel()
    try await Self.withHost(container: container, model: model) { host in
      let conversationID = try await host.apiClient.createConversation(
        session: host.defaultSession,
        request: EmbeddedCreateConversationRequest(
          modelRef: model.id.uuidString,
          userSystemPrompt: "sys",
          topic: "embedded-topic"
        )
      )

      let beforePatch = try #require(await host.runtimeSession.modelConversation(id: conversationID))
      let ifMatch = APILayer.conversationETag(revision: beforePatch.controlPlaneRevision)
      try await host.apiClient.patchConversation(
        session: host.defaultSession,
        conversationID: conversationID,
        patch: ConversationPatch(
          expectedRevision: beforePatch.controlPlaneRevision,
          description: "patched"
        ),
        ifMatch: ifMatch
      )

      let conversation = try #require(await host.runtimeSession.modelConversation(id: conversationID))
      #expect(conversation.description == "patched")
    }
  }

  @Test("strict tenancy rejects embedded create without bearer")
  func strictTenancyRequiresAuth() async throws {
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Self.makeModel()
    try await Self.withHost(
      container: container,
      model: model,
      tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true)
    ) { host in
      do {
        _ = try await host.apiClient.createConversation(
          session: EmbeddedHarnessAPISession(connectionNamespace: host.defaultSession.connectionNamespace),
          request: EmbeddedCreateConversationRequest(modelRef: model.id.uuidString)
        )
        Issue.record("Expected unauthorized embedded create")
      } catch let error as HarnessMutationTransportError {
        #expect(error == .unexpectedStatus(.unauthorized))
      }
    }
  }
}
