import Testing
import SwiftAgentHarness

@Suite("SwiftAgentHarness")
struct SwiftAgentHarnessTests {
    @Test("version is non-empty")
    func version() {
        #expect(!SwiftAgentHarness.version.isEmpty)
    }
}
