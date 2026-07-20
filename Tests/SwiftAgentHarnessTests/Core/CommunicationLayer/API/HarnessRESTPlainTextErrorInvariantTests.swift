import Foundation
import Testing

@Suite("Harness REST plain-text error invariants (LS4)")
struct HarnessRESTPlainTextErrorInvariantTests {
    private static let targetPath = RouteTenancyInventoryLoader.repositoryRoot(from: #filePath)
        .appendingPathComponent("Sources/SwiftAgentHarness/Core/CommunicationLayer/API/APILayerRESTModules.swift")

    @Test("APILayerRESTModules does not return plain-text error bodies")
    func noPlainTextErrorBodies() throws {
        let text = try String(contentsOf: Self.targetPath, encoding: .utf8)
        #expect(text.contains("body: .init(string:") == false)
        if text.contains("body: .init(string:") {
            Issue.record("APILayerRESTModules still uses body: .init(string:) for responses")
        }
    }
}
