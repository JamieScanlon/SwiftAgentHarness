import Foundation
import Testing
@testable import SwiftAgentHarness

private actor PerModelChangeCollector {
    var tuples: [(UUID, Int)] = []
    var poolHealth: [(queueDepth: Int, inFlight: Int)] = []

    func appendChange(_ item: (UUID, Int)) {
        tuples.append(item)
    }

    func appendHealth(_ payload: PoolHealthPayload) {
        poolHealth.append((payload.queueDepth, payload.inFlight))
    }
}

@Suite("ModelCallScheduler per-model inFlight")
struct ModelCallSchedulerPerModelInFlightTests {
    @Test("Acquire/release update per-model inFlight count and notify closure")
    func perModelCounterIncrementDecrement() async throws {
        let collector = PerModelChangeCollector()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            onPoolHealthChange: { payload in
                await collector.appendHealth(payload)
            },
            onModelInFlightChange: { modelID, count in
                await collector.appendChange((modelID, count))
            }
        )
        let modelID = UUID()
        await scheduler.acquire(for: modelID, priority: .foreground)
        let afterFirst = await scheduler.inFlightCount(for: modelID)
        #expect(afterFirst == 1)
        await scheduler.acquire(for: modelID, priority: .foreground)
        let afterSecond = await scheduler.inFlightCount(for: modelID)
        #expect(afterSecond == 2)
        await scheduler.release(for: modelID)
        await scheduler.release(for: modelID)
        let afterRelease = await scheduler.inFlightCount(for: modelID)
        #expect(afterRelease == 0)

        let changes = await collector.tuples
        let counts = changes.filter { $0.0 == modelID }.map { $0.1 }
        #expect(counts == [1, 2, 1, 0])
    }

    @Test("Per-model counts are independent across modelIDs")
    func perModelCountsIndependent() async throws {
        let collector = PerModelChangeCollector()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            onModelInFlightChange: { modelID, count in
                await collector.appendChange((modelID, count))
            }
        )
        let modelA = UUID()
        let modelB = UUID()
        await scheduler.acquire(for: modelA, priority: .foreground)
        await scheduler.acquire(for: modelB, priority: .foreground)
        await scheduler.acquire(for: modelA, priority: .foreground)
        let aCount = await scheduler.inFlightCount(for: modelA)
        let bCount = await scheduler.inFlightCount(for: modelB)
        #expect(aCount == 2)
        #expect(bCount == 1)

        let changes = await collector.tuples
        let aChanges = changes.filter { $0.0 == modelA }.map { $0.1 }
        let bChanges = changes.filter { $0.0 == modelB }.map { $0.1 }
        #expect(aChanges == [1, 2])
        #expect(bChanges == [1])
    }

    @Test("Global pool/health inFlight aggregates across models")
    func poolHealthAggregatesAcrossModels() async throws {
        let collector = PerModelChangeCollector()
        let scheduler = ModelCallScheduler(
            maxConcurrent: 4,
            onPoolHealthChange: { payload in
                await collector.appendHealth(payload)
            }
        )
        let modelA = UUID()
        let modelB = UUID()
        await scheduler.acquire(for: modelA, priority: .foreground)
        await scheduler.acquire(for: modelB, priority: .foreground)
        let snapshot = await scheduler.poolHealthSnapshot()
        #expect(snapshot.inFlight == 2)
        #expect(snapshot.queueDepth == 0)
    }

    @Test("inFlightCount(for:) returns 0 for never-acquired modelID")
    func unseenModelHasZeroCount() async throws {
        let scheduler = ModelCallScheduler(maxConcurrent: 1)
        let count = await scheduler.inFlightCount(for: UUID())
        #expect(count == 0)
    }
}
