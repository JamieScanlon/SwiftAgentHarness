import SwiftData
import Testing
@testable import SwiftAgentHarness

/// Regression smoke tests for harness-aligned cancellation wiring (`generationTask`, listener teardown).
@Suite("Agent Runtime — cancel generation")
struct AgentRuntimeCancelGenerationTests {
    @Test("cancelGeneration on idle HarnessRuntimeSession completes without throwing")
    func cancelGenerationSmoke() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let manager = HarnessRuntimeSession(container: container, harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container))
        await manager.cancelGeneration()
    }
}
