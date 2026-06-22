import Foundation
import Logging
import SwiftAgentKit
import Testing
import SwiftAgentHarness

@Suite("Public API surface (non-testable import)")
struct PublicAPISurfaceTests {
    @Test("SubAgentHostingPolicy is constructible with public members")
    func subAgentHostingPolicy() {
        let policy = SubAgentHostingPolicy(
            hostPersonaID: "host",
            delegationAllowlist: ["delegate-tool"],
            authScopeTags: ["scope"],
            routingDomain: "example.com",
            tenantScope: "tenant-a"
        )
        #expect(policy.hostPersonaID == "host")
        #expect(policy.delegationAllowlist == ["delegate-tool"])
    }

    @Test("SessionEntryID.generate is callable")
    func sessionEntryIDGenerate() {
        let id = SessionEntryID.generate()
        #expect(id.rawValue.count == 8)
    }

    @Test("Context compaction exports are constructible")
    func contextCompactionExports() {
        let cachePolicy = ContextCompactionCachePolicy(
            enabled: true,
            stablePrefixMessageCount: 4,
            ttlSeconds: 60
        )
        let scheduling = ContextCompactionLLMScheduling(
            scheduler: ModelCallScheduler(),
            modelID: UUID()
        )
        let transformer = ContextCompactionTransformer.makeProduction(
            config: .default,
            scheduling: scheduling
        )
        #expect(cachePolicy.enabled)
        #expect(transformer is ContextCompactionTransformer)
    }

    @Test("ModelManager and ModelPoolCostLedger initializers are public")
    func modelPoolExports() async {
        let manager = ModelManager(logger: Logger(label: "public-api-test"))
        let ledger = ModelPoolCostLedger()
        _ = await manager.getAvailableModels()
        await ledger.setConversationMaxUSD(conversationID: UUID(), maxUSD: 1.0)
    }

    @Test("APILayer wiring entry points are public")
    func apiLayerWiring() async throws {
        let api = APILayer(port: 0)
        let manager = ModelManager()
        await api.setModelManager(manager)
        await api.setBudgetReporting(NilBudgetReporting())
        await api.stop()
    }

    @Test("Session persistence configuration env accessors are public")
    func sessionPersistenceConfiguration() {
        _ = SessionPersistenceConfiguration.harnessOnDiskV2Configured
        _ = SessionPersistenceConfiguration.sessionAgentId
    }

    @Test("CompactionConcurrencyCoordinator is public")
    func compactionCoordinator() async {
        let coordinator = CompactionConcurrencyCoordinator()
        let acquired = await coordinator.tryAcquire(for: UUID())
        #expect(acquired)
        await coordinator.release(for: UUID())
    }
}
