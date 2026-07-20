import Foundation
import SwiftData
import SwiftAgentKit
import NIOCore
import Testing
import Vapor
@testable import SwiftAgentHarness

@Suite("EmbeddedHarnessAPIPrecondition", .serialized)
struct EmbeddedHarnessAPIPreconditionTests {
  private static func withHost(
    httpPreconditions: HTTPPreconditionPolicySettings,
    _ body: (EmbeddedHarnessHost, Model) async throws -> Void
  ) async throws {
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Model(
      protocol: .openAIAPI,
      modelName: "embedded-precondition:test",
      serverURL: URL(string: "http://localhost:1234")!,
      capabilities: [.completion],
      modelProtocol: .openAIAPI
    )
    let host = try await EmbeddedHarnessHost.makeForTesting(
      container: container,
      model: model,
      httpPreconditions: httpPreconditions
    )
    do {
      try await body(host, model)
    } catch {
      try await host.shutdown()
      throw error
    }
    try await host.shutdown()
  }

  @Test("PATCH returns 428 without If-Match when strict preconditions enabled")
  func patchRequiresIfMatch() async throws {
    try await Self.withHost(httpPreconditions: HTTPPreconditionPolicySettings(strictMode: true)) { host, model in
      let conversationID = try await host.apiClient.createConversation(
        session: host.defaultSession,
        request: EmbeddedCreateConversationRequest(modelRef: model.id.uuidString, userSystemPrompt: "sys")
      )

      do {
        let data = try JSONEncoder().encode(ConversationPatch(expectedRevision: 0, topic: "strict"))
        var headers = HTTPHeaders()
        headers.contentType = .json
        let response = try await host.apiClient.send(
          method: .PATCH,
          path: "/api/conversations/\(conversationID.uuidString)",
          session: host.defaultSession,
          headers: headers,
          body: ByteBuffer(data: data)
        )
        #expect(response.status == .preconditionRequired)
      } catch let error as HarnessMutationTransportError {
        #expect(error == .unexpectedStatus(.preconditionRequired))
      }
    }
  }
}
