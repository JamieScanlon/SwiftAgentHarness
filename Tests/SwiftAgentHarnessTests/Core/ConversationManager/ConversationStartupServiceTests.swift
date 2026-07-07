import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("ConversationStartupService")
struct ConversationStartupServiceTests {
    @Test("startup service is wired on HarnessRuntimeSession")
    func startupServiceWiredOnHost() async throws {
                let container = try HarnessTestModelContainer.makeInMemory()
        let host = HarnessRuntimeSession(
            container: container,
            harnessSessionPersistenceOverride: HarnessConversationTestFixtures.sharedInMemoryHarness(for: container)
        )
        let seeds = await host.conversationStartupService.budgetLedgerHydrationSeeds()
        #expect(seeds.isEmpty)
    }
}
