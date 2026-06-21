import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("SubAgentSpawnService")
struct SubAgentSpawnServiceTests {
    @Test("spawn service is wired on HarnessRuntimeSession")
    func spawnServiceWiredOnHost() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let pool = await host.subAgentSpawnService.subAgentPool
        #expect(pool is DefaultSubAgentPool)
    }
}
