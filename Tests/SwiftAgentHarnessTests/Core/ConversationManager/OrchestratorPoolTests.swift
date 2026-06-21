import Foundation
import Testing
import SwiftAgentKit
import SwiftAgentKitMCP
import SwiftAgentKitOrchestrator
@testable import SwiftAgentHarness

private extension MCPManager {
    func testing_markInitialized() {
        state = .initialized
    }
}

private enum OrchestratorPoolTestSupport {
    static func makeStubLLM() -> StubTurnLoopLLM {
        StubTurnLoopLLM()
    }

    static func makeOrchestrator() -> SwiftAgentKitOrchestrator {
        SwiftAgentKitOrchestrator(
            llm: makeStubLLM(),
            config: OrchestratorConfig(streamingEnabled: true, mcpEnabled: false, a2aEnabled: false)
        )
    }

    static func makeBuilt(conversationID: UUID, orchestrator: SwiftAgentKitOrchestrator) -> BuiltOrchestrator {
        BuiltOrchestrator(
            orchestrator: orchestrator,
            queuedLLM: QueuedLLM(baseLLM: StatefulLLM(baseLLM: makeStubLLM())),
            conversationID: conversationID
        )
    }

    static func makeOrchestratorWithSharedMCP(_ sharedMCP: MCPManager) -> SwiftAgentKitOrchestrator {
        SwiftAgentKitOrchestrator(
            llm: makeStubLLM(),
            config: OrchestratorConfig(
                streamingEnabled: true,
                mcpEnabled: true,
                a2aIntegration: .disabled,
                acpIntegration: .disabled
            ),
            mcpManager: sharedMCP
        )
    }

    /// Matches `HarnessRuntimeSessionFactory` → `releasePooledOrchestrator` (not `shutdown()`).
    static func productionPoolTeardown(_ orchestrator: SwiftAgentKitOrchestrator) async {
        await orchestrator.endMessageStream()
    }
}

@Suite("OrchestratorPool regression locks")
struct OrchestratorPoolRegressionTests {
    @Test("teardown does not kill shared managers")
    func teardownDoesNotKillSharedManagers() async {
        let sharedMCP = MCPManager()
        await sharedMCP.testing_markInitialized()

        let pool = OrchestratorPool(maxEntries: 2, idleTTLSeconds: 0)
        await pool.setTeardownHandler { orchestrator in
            await OrchestratorPoolTestSupport.productionPoolTeardown(orchestrator)
        }

        let convA = UUID()
        let convB = UUID()
        let convC = UUID()
        let modelName = "regression:shared-mcp"

        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            OrchestratorPoolTestSupport.makeBuilt(
                conversationID: convA,
                orchestrator: OrchestratorPoolTestSupport.makeOrchestratorWithSharedMCP(sharedMCP)
            )
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            OrchestratorPoolTestSupport.makeBuilt(
                conversationID: convB,
                orchestrator: OrchestratorPoolTestSupport.makeOrchestratorWithSharedMCP(sharedMCP)
            )
        }
        guard acquisitionA != nil, acquisitionB != nil else {
            Issue.record("Expected pooled acquisitions")
            return
        }

        await pool.release(acquisitionA!.handle)
        await pool.invalidate(conversationID: convA)
        #expect(await sharedMCP.state == .initialized)
        #expect(await pool.orchestrator(for: convB) != nil)

        let acquisitionC = await pool.acquire(conversationID: convC, modelName: modelName) {
            OrchestratorPoolTestSupport.makeBuilt(
                conversationID: convC,
                orchestrator: OrchestratorPoolTestSupport.makeOrchestratorWithSharedMCP(sharedMCP)
            )
        }
        guard acquisitionC != nil else {
            Issue.record("Expected eviction-driven acquisition")
            return
        }
        #expect(await sharedMCP.state == .initialized)
        #expect(await pool.orchestrator(for: convB) != nil)

        await pool.release(acquisitionC!.handle)
        let survivingOrchestrator = acquisitionB!.orchestrator
        await pool.release(acquisitionB!.handle)
        await pool.clearBinding()
        #expect(await sharedMCP.state == .initialized)

        await survivingOrchestrator.shutdown()
        #expect(await sharedMCP.state == .notReady)
    }

    @Test("reentrant concurrent acquire builds once")
    func reentrantConcurrentAcquireBuildsOnce() async {
        actor BuildCounter {
            private(set) var count = 0
            func recordBuild() { count += 1 }
            func buildCount() -> Int { count }
        }

        let pool = OrchestratorPool(maxEntries: 4)
        let conversationID = UUID()
        let modelName = "regression:reentrant-acquire"
        let counter = BuildCounter()
        let sharedOrchestrator = OrchestratorPoolTestSupport.makeOrchestrator()

        async let first = pool.acquire(conversationID: conversationID, modelName: modelName) {
            await counter.recordBuild()
            try? await Task.sleep(nanoseconds: 25_000_000)
            return OrchestratorPoolTestSupport.makeBuilt(
                conversationID: conversationID,
                orchestrator: sharedOrchestrator
            )
        }
        async let second = pool.acquire(conversationID: conversationID, modelName: modelName) {
            await counter.recordBuild()
            return OrchestratorPoolTestSupport.makeBuilt(
                conversationID: conversationID,
                orchestrator: OrchestratorPoolTestSupport.makeOrchestrator()
            )
        }
        async let third = pool.acquire(conversationID: conversationID, modelName: modelName) {
            await counter.recordBuild()
            return OrchestratorPoolTestSupport.makeBuilt(
                conversationID: conversationID,
                orchestrator: OrchestratorPoolTestSupport.makeOrchestrator()
            )
        }

        let acquisitions = await (first, second, third)
        #expect(await counter.buildCount() == 1)
        #expect(acquisitions.0 != nil)
        #expect(acquisitions.1 != nil)
        #expect(acquisitions.2 != nil)
        #expect(acquisitions.0?.orchestrator === acquisitions.1?.orchestrator)
        #expect(acquisitions.1?.orchestrator === acquisitions.2?.orchestrator)
        #expect(acquisitions.0?.handle.entryID == acquisitions.1?.handle.entryID)
        #expect(acquisitions.1?.handle.entryID == acquisitions.2?.handle.entryID)
        #expect(await pool.entryCount() == 1)

        if let first = acquisitions.0 { await pool.release(first.handle) }
        if let second = acquisitions.1 { await pool.release(second.handle) }
        if let third = acquisitions.2 { await pool.release(third.handle) }
    }
}

@Suite("OrchestratorPool")
struct OrchestratorPoolTests {
    private func makeStubLLM() -> StubTurnLoopLLM {
        OrchestratorPoolTestSupport.makeStubLLM()
    }

    private func makeOrchestrator() -> SwiftAgentKitOrchestrator {
        OrchestratorPoolTestSupport.makeOrchestrator()
    }

    private func makeBuilt(conversationID: UUID, orchestrator: SwiftAgentKitOrchestrator) -> BuiltOrchestrator {
        OrchestratorPoolTestSupport.makeBuilt(conversationID: conversationID, orchestrator: orchestrator)
    }

    @Test("invalidate lifecycle updates orphaned pool entry not side map")
    func invalidateLifecycleUpdatesOrphanedPoolEntry() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let conversationID = UUID()
        let modelName = "invalidate-lifecycle:test"
        let runID = UUID()

        let first = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: makeOrchestrator())
        }
        guard let first else {
            Issue.record("Expected first acquisition")
            return
        }

        await pool.invalidate(conversationID: conversationID)
        await pool.mutateLifecycle(for: conversationID) { lifecycle in
            lifecycle.currentStreamingRunID = runID
        }

        let orphanedLifecycle = await pool.lifecycleSnapshot(for: conversationID)
        #expect(orphanedLifecycle?.currentStreamingRunID == runID)

        let freshOrchestrator = makeOrchestrator()
        let second = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: freshOrchestrator)
        }
        let freshLifecycle = await pool.lifecycleSnapshot(for: conversationID)
        #expect(freshLifecycle?.currentStreamingRunID == nil)

        if let second { await pool.release(second.handle) }
        await pool.release(first.handle)
    }

    @Test("max entries cap evicts idle LRU entry")
    func maxEntriesEvictsIdleLRUEntry() async {
        let pool = OrchestratorPool(maxEntries: 2, idleTTLSeconds: 300)
        let convA = UUID()
        let convB = UUID()
        let convC = UUID()
        let modelName = "max-entries:test"

        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            makeBuilt(conversationID: convA, orchestrator: makeOrchestrator())
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            makeBuilt(conversationID: convB, orchestrator: makeOrchestrator())
        }
        if let acquisitionA { await pool.release(acquisitionA.handle) }
        if let acquisitionB { await pool.release(acquisitionB.handle) }

        let acquisitionC = await pool.acquire(conversationID: convC, modelName: modelName) {
            makeBuilt(conversationID: convC, orchestrator: makeOrchestrator())
        }

        #expect(await pool.entryCount() == 2)
        #expect(await pool.orchestrator(for: convA) == nil)
        #expect(await pool.orchestrator(for: convB) != nil)
        #expect(await pool.orchestrator(for: convC) != nil)
        if let acquisitionC { await pool.release(acquisitionC.handle) }
    }

    @Test("reacquire awaits prior teardown for same key")
    func reacquireAwaitsPriorTeardownForSameKey() async {
        actor TeardownTracker {
            private(set) var teardownCount = 0
            private(set) var buildStartedBeforeTeardownFinished = false
            private var teardownInFlight = false

            func beginTeardown() {
                teardownCount += 1
                teardownInFlight = true
            }

            func endTeardown() {
                teardownInFlight = false
            }

            func recordBuildStart() {
                buildStartedBeforeTeardownFinished = teardownInFlight
            }

            func teardownCountValue() -> Int { teardownCount }
            func buildStartedBeforeTeardownFinishedValue() -> Bool { buildStartedBeforeTeardownFinished }
        }

        let pool = OrchestratorPool(maxEntries: 4, idleTTLSeconds: 0)
        let tracker = TeardownTracker()
        await pool.setTeardownHandler { _ in
            await tracker.beginTeardown()
            try? await Task.sleep(nanoseconds: 50_000_000)
            await tracker.endTeardown()
        }

        let conversationID = UUID()
        let modelName = "teardown-order:test"
        let firstOrchestrator = makeOrchestrator()
        let first = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: firstOrchestrator)
        }
        guard let first else {
            Issue.record("Expected first acquisition")
            return
        }
        await pool.release(first.handle)
        await pool.evictIdle()

        let secondOrchestrator = makeOrchestrator()
        _ = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            await tracker.recordBuildStart()
            return makeBuilt(conversationID: conversationID, orchestrator: secondOrchestrator)
        }

        #expect(await tracker.teardownCountValue() == 1)
        #expect(await tracker.buildStartedBeforeTeardownFinishedValue() == false)
    }

    @Test("clear binding removes pooled entries")
    func clearBindingRemovesPooledEntries() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let conversationID = UUID()
        let modelName = "pool:test"
        let acquisition = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: makeOrchestrator())
        }
        #expect(acquisition != nil)
        #expect(await pool.orchestrator(for: conversationID) != nil)
        if let acquisition { await pool.release(acquisition.handle) }
        await pool.clearBinding()
        #expect(await pool.orchestrator(for: conversationID) == nil)
    }

    @Test("acquire returns same instance for same key")
    func acquireSameKey() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let conversationID = UUID()
        let modelName = "acquire:test"
        let orchestrator = makeOrchestrator()
        let first = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: orchestrator)
        }
        let second = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            nil
        }
        #expect(first != nil)
        #expect(second != nil)
        #expect(first?.orchestrator === second?.orchestrator)
        if let first {
            await pool.release(first.handle)
            await pool.release(first.handle)
        }
    }

    @Test("different conversations get distinct instances")
    func distinctConversations() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let convA = UUID()
        let convB = UUID()
        let modelName = "distinct:test"
        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            makeBuilt(conversationID: convA, orchestrator: makeOrchestrator())
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            makeBuilt(conversationID: convB, orchestrator: makeOrchestrator())
        }
        #expect(acquisitionA?.orchestrator !== acquisitionB?.orchestrator)
        if let acquisitionA { await pool.release(acquisitionA.handle) }
        if let acquisitionB { await pool.release(acquisitionB.handle) }
    }

    @Test("invalidate during active acquire forces fresh orchestrator on reacquire")
    func invalidateDuringActiveAcquireForcesFreshBuild() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let conversationID = UUID()
        let modelName = "invalidate-active:test"
        let staleOrchestrator = makeOrchestrator()

        let first = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: staleOrchestrator)
        }
        guard let first else {
            Issue.record("Expected first acquisition")
            return
        }

        await pool.invalidate(conversationID: conversationID)
        #expect(await pool.orchestrator(for: conversationID) == nil)

        let freshOrchestrator = makeOrchestrator()
        let second = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: freshOrchestrator)
        }
        #expect(second?.orchestrator === freshOrchestrator)
        #expect(second?.orchestrator !== staleOrchestrator)
        #expect(second?.handle.entryID != first.handle.entryID)

        if let second { await pool.release(second.handle) }
        await pool.release(first.handle)
    }

    @Test("invalidate removes only targeted conversation entry")
    func invalidateIsolation() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let convA = UUID()
        let convB = UUID()
        let modelName = "invalidate:test"
        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            makeBuilt(conversationID: convA, orchestrator: makeOrchestrator())
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            makeBuilt(conversationID: convB, orchestrator: makeOrchestrator())
        }
        if let acquisitionA { await pool.release(acquisitionA.handle) }
        if let acquisitionB { await pool.release(acquisitionB.handle) }
        await pool.invalidate(conversationID: convA)
        #expect(await pool.orchestrator(for: convA) == nil)
        #expect(await pool.orchestrator(for: convB) != nil)
    }

    @Test("eviction reclaims idle entry at refCount zero")
    func evictionReclaimsIdleEntry() async {
        let pool = OrchestratorPool(maxEntries: 4, idleTTLSeconds: 0)
        let conversationID = UUID()
        let modelName = "evict:test"
        let acquisition = await pool.acquire(conversationID: conversationID, modelName: modelName) {
            makeBuilt(conversationID: conversationID, orchestrator: makeOrchestrator())
        }
        if let acquisition {
            await pool.release(acquisition.handle)
        }
        await pool.evictIdle()
        #expect(await pool.orchestrator(for: conversationID) == nil)
    }

    @Test("multiple idle entries remain conversation keyed")
    func multipleIdleEntriesRemainConversationKeyed() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let convA = UUID()
        let convB = UUID()
        let modelName = "multi-idle:test"
        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            makeBuilt(conversationID: convA, orchestrator: makeOrchestrator())
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            makeBuilt(conversationID: convB, orchestrator: makeOrchestrator())
        }
        if let acquisitionA { await pool.release(acquisitionA.handle) }
        if let acquisitionB { await pool.release(acquisitionB.handle) }

        #expect(await pool.orchestrator(for: convA) != nil)
        #expect(await pool.orchestrator(for: convB) != nil)
    }

    @Test("pending teardown map self-cleans after distinct key evictions")
    func pendingTeardownMapSelfCleans() async {
        actor TeardownTracker {
            private(set) var teardownCount = 0
            func recordTeardown() { teardownCount += 1 }
            func count() -> Int { teardownCount }
        }

        let pool = OrchestratorPool(maxEntries: 2, idleTTLSeconds: 0)
        let tracker = TeardownTracker()
        await pool.setTeardownHandler { _ in
            await tracker.recordTeardown()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let modelName = "teardown-cleanup:test"
        var handles: [OrchestratorHandle] = []
        for _ in 0..<4 {
            let conversationID = UUID()
            let acquisition = await pool.acquire(conversationID: conversationID, modelName: modelName) {
                makeBuilt(conversationID: conversationID, orchestrator: makeOrchestrator())
            }
            guard let acquisition else {
                Issue.record("Expected acquisition")
                return
            }
            handles.append(acquisition.handle)
            await pool.release(acquisition.handle)
            await pool.evictIdle()
        }

        await pool.testing_drainPendingTeardowns()
        #expect(await tracker.count() == 4)
        #expect(await pool.testing_pendingTeardownCount() == 0)
    }

    @Test("fresh build reserves refCount before concurrent eviction pressure")
    func freshBuildReservesRefCountUnderEvictionPressure() async {
        actor BuildGate {
            private var inFlight = 0
            private var maxInFlight = 0
            private var minEntryCountDuringBuild = Int.max

            func beginBuild() {
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
            }

            func endBuild() {
                inFlight -= 1
            }

            func recordEntryCount(_ count: Int) {
                minEntryCountDuringBuild = min(minEntryCountDuringBuild, count)
            }

            func maxInFlightValue() -> Int { maxInFlight }
            func minEntryCountDuringBuildValue() -> Int { minEntryCountDuringBuild }
        }

        let pool = OrchestratorPool(maxEntries: 2, idleTTLSeconds: 300)
        let gate = BuildGate()
        let modelName = "refcount-reserve:test"
        let heldA = UUID()
        let heldB = UUID()
        let newC = UUID()
        let newD = UUID()

        let holdA = await pool.acquire(conversationID: heldA, modelName: modelName) {
            makeBuilt(conversationID: heldA, orchestrator: makeOrchestrator())
        }
        let holdB = await pool.acquire(conversationID: heldB, modelName: modelName) {
            makeBuilt(conversationID: heldB, orchestrator: makeOrchestrator())
        }
        guard holdA != nil, holdB != nil else {
            Issue.record("Expected held acquisitions")
            return
        }

        async let buildC = pool.acquire(conversationID: newC, modelName: modelName) {
            await gate.beginBuild()
            await gate.recordEntryCount(await pool.entryCount())
            try? await Task.sleep(nanoseconds: 30_000_000)
            await gate.endBuild()
            return makeBuilt(conversationID: newC, orchestrator: makeOrchestrator())
        }
        async let buildD = pool.acquire(conversationID: newD, modelName: modelName) {
            await gate.beginBuild()
            await gate.recordEntryCount(await pool.entryCount())
            try? await Task.sleep(nanoseconds: 30_000_000)
            await gate.endBuild()
            return makeBuilt(conversationID: newD, orchestrator: makeOrchestrator())
        }

        let acquisitions = await (buildC, buildD)
        #expect(acquisitions.0 != nil)
        #expect(acquisitions.1 != nil)
        #expect(await gate.maxInFlightValue() == 2)
        #expect(await gate.minEntryCountDuringBuildValue() >= 2)

        if let acquisitionsC = acquisitions.0 { await pool.release(acquisitionsC.handle) }
        if let acquisitionsD = acquisitions.1 { await pool.release(acquisitionsD.handle) }
        if let holdA { await pool.release(holdA.handle) }
        if let holdB { await pool.release(holdB.handle) }
    }

    @Test("no-arg lifecycle snapshot fails closed when multiple entries stream")
    func noArgLifecycleFailsClosedWithMultipleStreams() async {
        let pool = OrchestratorPool(maxEntries: 4)
        let convA = UUID()
        let convB = UUID()
        let modelName = "multi-stream:test"
        let runA = UUID()
        let runB = UUID()

        let acquisitionA = await pool.acquire(conversationID: convA, modelName: modelName) {
            makeBuilt(conversationID: convA, orchestrator: makeOrchestrator())
        }
        let acquisitionB = await pool.acquire(conversationID: convB, modelName: modelName) {
            makeBuilt(conversationID: convB, orchestrator: makeOrchestrator())
        }
        guard acquisitionA != nil, acquisitionB != nil else {
            Issue.record("Expected acquisitions")
            return
        }

        await pool.mutateLifecycle(for: convA) { lifecycle in
            lifecycle.activeStreamingConversationID = convA
            lifecycle.currentStreamingRunID = runA
            lifecycle.generationTask = Task { try? await Task.sleep(nanoseconds: .max) }
        }
        await pool.mutateLifecycle(for: convB) { lifecycle in
            lifecycle.activeStreamingConversationID = convB
            lifecycle.currentStreamingRunID = runB
            lifecycle.generationTask = Task { try? await Task.sleep(nanoseconds: .max) }
        }

        let noArgSnapshot = await pool.activeStreamingLifecycleSnapshot()
        #expect(noArgSnapshot.currentStreamingRunID == nil)

        let snapshotA = await pool.lifecycleSnapshot(for: convA)
        let snapshotB = await pool.lifecycleSnapshot(for: convB)
        #expect(snapshotA?.currentStreamingRunID == runA)
        #expect(snapshotB?.currentStreamingRunID == runB)

        if let acquisitionA { await pool.release(acquisitionA.handle) }
        if let acquisitionB { await pool.release(acquisitionB.handle) }
    }
}
