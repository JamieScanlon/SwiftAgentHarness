import Foundation
import Testing

@Suite("Harness mutation bypass invariants (LS1)")
struct HarnessMutationBypassInvariantTests {
  private static let repositoryRoot: URL = {
    let fileURL = URL(fileURLWithPath: #filePath)
    return fileURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }()

  private static let sourcesRoot = repositoryRoot.appendingPathComponent("Sources/SwiftAgentHarness")

  private static let allowedRelativePaths: Set<String> = [
    "Core/CommunicationLayer/API/APILayer.swift",
    "Core/CommunicationLayer/API/APILayerTransportSupport.swift",
    "Core/CommunicationLayer/API/APILayerChatSplitGatewayServices.swift",
    "Core/CommunicationLayer/API/HarnessEmbeddedMutation.swift",
    "Core/AgentRuntime/RuntimeStreamingOrchestrationService.swift",
    "Core/ConversationManager/HarnessRuntimeSession+Messaging.swift",
    "Core/AgentRuntime/AgentRuntimeSessionService.swift",
    "Core/AgentRuntime/AgentRuntimeSessionService+HarnessBridge.swift",
    "Core/Memory/MemorySubAgentSpawnWiring.swift",
  ]

  @Test("production sources do not call apiSendMessageAndStreamResponse outside allowlist")
  func apiSendMessageBypassInventory() throws {
    let violations = try Self.findViolations(pattern: "apiSendMessageAndStreamResponse(")
    #expect(violations.isEmpty)
    if !violations.isEmpty {
      Issue.record("Unexpected apiSendMessageAndStreamResponse call sites: \(violations.joined(separator: ", "))")
    }
  }

  private static func findViolations(pattern: String) throws -> [String] {
    let enumerator = FileManager.default.enumerator(
      at: sourcesRoot,
      includingPropertiesForKeys: nil
    )
    var violations: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      let relative = url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
      if allowedRelativePaths.contains(relative) { continue }
      let text = try String(contentsOf: url, encoding: .utf8)
      if text.contains(pattern) {
        violations.append(relative)
      }
    }
    return violations.sorted()
  }
}
