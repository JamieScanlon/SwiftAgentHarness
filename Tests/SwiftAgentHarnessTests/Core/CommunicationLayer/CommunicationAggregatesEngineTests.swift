import Foundation
import Testing
@testable import SwiftAgentHarness

private final class AggregateClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

@Suite("CommunicationAggregatesEngine")
struct CommunicationAggregatesEngineTests {
    @Test("pool snapshot computes rolling error rate and latency quantiles")
    func poolSnapshotComputesErrorRateAndLatency() async {
        let clock = AggregateClock(now: Date(timeIntervalSince1970: 0))
        let engine = CommunicationAggregatesEngine(
            now: { clock.now },
            maxAttemptSamples: 16,
            maxLatencySamples: 16
        )
        let modelID = UUID()
        let c1 = UUID()
        await engine.recordAttempt(modelID: modelID, callID: c1)
        clock.now = Date(timeIntervalSince1970: 0.100)
        await engine.recordCompletion(modelID: modelID, callID: c1)

        let c2 = UUID()
        await engine.recordAttempt(modelID: modelID, callID: c2)
        clock.now = Date(timeIntervalSince1970: 0.300)
        await engine.recordFailure(modelID: modelID, callID: c2, rateLimited: false)

        let snapshot = await engine.poolSnapshot()
        #expect(snapshot.errorRate == 0.5)
        #expect(snapshot.rollingLatencyMsP50 != nil)
        #expect(snapshot.rollingLatencyMsP95 != nil)
    }

    @Test("model snapshot surfaces rate-limit window as active while fresh")
    func modelSnapshotRateLimitWindow() async {
        let clock = AggregateClock(now: Date(timeIntervalSince1970: 0))
        let engine = CommunicationAggregatesEngine(
            now: { clock.now },
            maxAttemptSamples: 16,
            maxLatencySamples: 16,
            rateLimitWindowSeconds: 60
        )
        let modelID = UUID()
        let callID = UUID()
        await engine.recordAttempt(modelID: modelID, callID: callID)
        clock.now = Date(timeIntervalSince1970: 0.2)
        await engine.recordFailure(modelID: modelID, callID: callID, rateLimited: true)

        let active = await engine.snapshot(for: modelID)
        #expect(active.rateLimitWindow?.active == true)

        clock.now = Date(timeIntervalSince1970: 120)
        let inactive = await engine.snapshot(for: modelID)
        #expect(inactive.rateLimitWindow?.active == false)
    }

    @Test("model snapshot computes tokens-per-second from completion samples")
    func modelSnapshotComputesTokensPerSecond() async {
        let clock = AggregateClock(now: Date(timeIntervalSince1970: 0))
        let engine = CommunicationAggregatesEngine(
            now: { clock.now },
            maxAttemptSamples: 16,
            maxLatencySamples: 16
        )
        let modelID = UUID()
        let callID = UUID()
        await engine.recordAttempt(modelID: modelID, callID: callID)
        clock.now = Date(timeIntervalSince1970: 2)
        await engine.recordCompletion(modelID: modelID, callID: callID, completionTokens: 40)
        let snapshot = await engine.snapshot(for: modelID)
        #expect(snapshot.recentTokensPerSecond == 20)
    }
}

