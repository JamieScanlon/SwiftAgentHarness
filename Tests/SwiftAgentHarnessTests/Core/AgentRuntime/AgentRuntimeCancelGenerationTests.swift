import SwiftData
import Testing
@testable import SwiftAgentHarness

/// Regression smoke tests for harness-aligned cancellation wiring (`generationTask`, listener teardown).
@Suite("Agent Runtime — cancel generation")
struct AgentRuntimeCancelGenerationTests {
    @Test("cancelGeneration on idle HarnessRuntimeSession completes without throwing")
    func cancelGenerationSmoke() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        await manager.cancelGeneration()
    }
}
