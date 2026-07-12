import Foundation
import SwiftData
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Trigger embedded loopback", .serialized)
struct TriggerEmbeddedLoopbackTests {
  @Test("EmbeddedHarnessHost registers mutation transport for trigger wiring")
  func hostRegistersMutationTransport() async throws {
    await HarnessMutationTransportHolder.shared.setTransport(nil)
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Model(
      protocol: .openAIAPI,
      modelName: "trigger-loopback:test",
      serverURL: URL(string: "http://localhost:1234")!,
      capabilities: [.completion],
      modelProtocol: .openAIAPI
    )
    let host = try await EmbeddedHarnessHost.makeForTesting(container: container, model: model)
    do {
      #expect(await HarnessMutationTransportHolder.shared.currentTransport() != nil)
    } catch {
      try? await host.shutdown()
      throw error
    }
    try await host.shutdown()
  }

  @Test("HarnessTriggerRuntimeAdapter falls back to runtime gateway when transport unset")
  func triggerAdapterUsesRuntimeFallback() async throws {
    await HarnessMutationTransportHolder.shared.setTransport(nil)
    let container = try HarnessTestModelContainer.makeInMemory()
    let model = Model(
      protocol: .openAIAPI,
      modelName: "trigger-loopback:fallback",
      serverURL: URL(string: "http://localhost:1234")!,
      capabilities: [.completion],
      modelProtocol: .openAIAPI
    )
    let runtimeSession = HarnessRuntimeSession(
      container: container,
      harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
    )
    let conversationID = try await runtimeSession.createConversation(with: model, userSystemPrompt: "sys")
    let graph = await HarnessConversationTestFixtures.makeServiceGraph(from: runtimeSession)

    let adapter = HarnessTriggerRuntimeAdapter(runtime: graph.runtime)
    try await adapter.dispatchTriggerMessage(
      conversationID: conversationID,
      text: "trigger body",
      systemReminder: nil,
      inputTrustRaw: MessageInputTrust.automation.rawValue,
      resolvedInputTrustClass: .lowTrust,
      enableTools: false,
      enableAgents: false,
      originSurface: "cron",
      originSenderID: "job-1"
    )

    let messages = try await runtimeSession.listMessages(conversationID: conversationID)
    #expect(messages.contains(where: { $0.role == .user && $0.content.contains("trigger body") }))
  }
}
