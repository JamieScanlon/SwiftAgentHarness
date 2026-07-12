import Foundation
import Testing

@Suite("Harness legacy WS mutation invariants (LS3)")
struct HarnessLegacyWSMutationInvariantTests {
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

    private static let bannedPatterns: [(pattern: String, label: String)] = [
        ("apiSetOrchestrationStateOutOfBandPush", "removed OOB push API"),
        ("apiClearOrchestrationStateOutOfBandPush", "removed OOB push API"),
        ("apiOrchestratorBoundConversationID", "removed orchestrator-bound routing seam"),
        ("orchestratorBoundConversationID()", "removed orchestrator-bound routing seam"),
        ("setOrchestrationStateOutOfBandPush", "removed OOB push registration"),
        ("clearOrchestrationStateOutOfBandPush", "removed OOB push registration"),
    ]

    @Test("production sources do not retain legacy WS mutation or OOB routing seams")
    func legacyWSMutationInventory() throws {
        var violations: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: Self.sourcesRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: Self.sourcesRoot.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            for entry in Self.bannedPatterns where text.contains(entry.pattern) {
                violations.append("\(relative): \(entry.label)")
            }
        }
        #expect(violations.isEmpty)
        if !violations.isEmpty {
            Issue.record("Legacy WS mutation remnants: \(violations.joined(separator: ", "))")
        }
    }
}
