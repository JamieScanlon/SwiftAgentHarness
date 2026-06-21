import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationStartupService")
struct ConversationStartupServiceTests {
    @Test("startup service is wired on HarnessRuntimeSession")
    func startupServiceWiredOnHost() async throws {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let seeds = await host.conversationStartupService.budgetLedgerHydrationSeeds()
        #expect(seeds.isEmpty)
    }
}
