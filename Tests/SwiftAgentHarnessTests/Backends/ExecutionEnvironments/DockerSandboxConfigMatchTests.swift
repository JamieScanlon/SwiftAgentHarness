import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Docker sandbox config match")
struct DockerSandboxConfigMatchTests {
    @Test("not running always matches")
    func notRunningMatches() {
        #expect(DockerSandboxConfigMatch.matches(running: false, labelHash: nil, currentHash: "abc123"))
        #expect(DockerSandboxConfigMatch.matches(running: false, labelHash: "old", currentHash: "new"))
    }

    @Test("running matches when label equals current hash")
    func runningMatchesWhenLabelEqualsHash() {
        #expect(DockerSandboxConfigMatch.matches(running: true, labelHash: "abc123", currentHash: "abc123"))
    }

    @Test("running mismatches when label differs or missing")
    func runningMismatchesOnDrift() {
        #expect(!DockerSandboxConfigMatch.matches(running: true, labelHash: "old", currentHash: "new"))
        #expect(!DockerSandboxConfigMatch.matches(running: true, labelHash: nil, currentHash: "new"))
    }
}
