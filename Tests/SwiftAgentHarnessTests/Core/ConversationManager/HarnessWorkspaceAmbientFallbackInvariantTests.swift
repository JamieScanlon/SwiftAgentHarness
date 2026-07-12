import Foundation
import Testing

@Suite("Harness workspace ambient fallback invariants (LS2)")
struct HarnessWorkspaceAmbientFallbackInvariantTests {
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
        "Core/ConversationManager/HarnessWorkspaceResolver.swift",
        "Core/ConversationManager/ConversationManager.swift",
        "Core/Memory/MemoryCLI.swift",
        "Backends/ExecutionEnvironments/ExecutablePathResolver.swift",
    ]

    @Test("production sources do not use harnessPersistenceCwd ambient fallback outside allowlist")
    func harnessPersistenceCwdAmbientFallbackInventory() throws {
        let violations = try Self.findViolations(pattern: "harnessPersistenceCwd ?? FileManager.default.currentDirectoryPath")
        #expect(violations.isEmpty)
        if !violations.isEmpty {
            Issue.record("Unexpected ambient cwd fallback sites: \(violations.joined(separator: ", "))")
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
