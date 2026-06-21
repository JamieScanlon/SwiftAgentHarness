import Foundation
import SwiftData
import Testing
@testable import SwiftAgentHarness

@Suite("HarnessRuntimeSessionFactory wiring")
struct HarnessRuntimeSessionFactoryWiringTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = HarnessPersistenceSchema.latest
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test("makeForTesting wires collaborators without precondition failures")
    func makeForTestingCompletes() async throws {
        let container = try makeContainer()
        let host = HarnessConversationTestFixtures.makeRuntimeSession(container: container)
        let services = await host.services

        let modeCtx = await services.orchestratorRuntimeService.installedModePolicy.defaultSessionModePolicyContext()
        #expect(modeCtx.interactionMode == .chat)

        let spawnReachable = await services.subAgentSpawnService.subAgentLifecyclePublisherConfigured()
        #expect(spawnReachable == false)
    }
}
