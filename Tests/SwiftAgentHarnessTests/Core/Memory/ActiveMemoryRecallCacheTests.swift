import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ActiveMemoryRecallCache")
struct ActiveMemoryRecallCacheTests {
    private func makeKey(lane: RecallLane, fp: String? = nil) -> ActiveMemoryRecallCache.Key {
        ActiveMemoryRecallCache.Key(conversationID: UUID(), lane: lane, queryFingerprint: fp)
    }

    @Test("store then fresh returns entry within TTL")
    func storeThenFreshHit() async {
        let cache = ActiveMemoryRecallCache()
        let key = makeKey(lane: .standing)
        await cache.store(key, summary: "profile summary")
        let result = await cache.fresh(key, ttlMs: 60_000)
        #expect(result == "profile summary")
    }

    @Test("nil store removes entry")
    func storeNilRemovesEntry() async {
        let cache = ActiveMemoryRecallCache()
        let key = makeKey(lane: .standing)
        await cache.store(key, summary: "profile summary")
        await cache.store(key, summary: nil)
        let result = await cache.fresh(key, ttlMs: 60_000)
        #expect(result == nil)
    }

    @Test("fresh returns nil after TTL expires")
    func freshReturnsNilAfterExpiry() async {
        let cache = ActiveMemoryRecallCache()
        let key = makeKey(lane: .situational, fp: "what is grafana")
        await cache.store(key, summary: "some context")
        let result = await cache.fresh(key, ttlMs: 0)
        #expect(result == nil)
    }

    @Test("situational entries are keyed separately by query fingerprint")
    func situationalKeyedByQuery() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache()
        let key1 = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "query-a")
        let key2 = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "query-b")
        await cache.store(key1, summary: "result-a")
        await cache.store(key2, summary: "result-b")
        #expect(await cache.fresh(key1, ttlMs: 60_000) == "result-a")
        #expect(await cache.fresh(key2, ttlMs: 60_000) == "result-b")
    }

    @Test("standing and situational for same conversation are independent")
    func standingAndSituationalAreIndependent() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache()
        let standing = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .standing, queryFingerprint: nil)
        let situational = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "q")
        await cache.store(standing, summary: "user prefs")
        await cache.store(situational, summary: "project context")
        #expect(await cache.fresh(standing, ttlMs: 60_000) == "user prefs")
        #expect(await cache.fresh(situational, ttlMs: 60_000) == "project context")
    }

    @Test("in-flight task dedupe: setInFlight then existingInFlight returns same task")
    func inFlightDedupe() async {
        let cache = ActiveMemoryRecallCache()
        let key = makeKey(lane: .standing)
        let task = Task<String?, Never> { "warm result" }
        await cache.setInFlight(key, task: task)
        let existing = await cache.existingInFlight(key)
        #expect(existing != nil)
        task.cancel()
    }

    @Test("store clears in-flight for that key")
    func storeClearsInFlight() async {
        let cache = ActiveMemoryRecallCache()
        let key = makeKey(lane: .standing)
        let task = Task<String?, Never> { "result" }
        await cache.setInFlight(key, task: task)
        await cache.store(key, summary: "result")
        #expect(await cache.existingInFlight(key) == nil)
    }

    @Test("invalidate with lane removes only that lane")
    func invalidateLaneSpecific() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache()
        let standing = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .standing, queryFingerprint: nil)
        let situational = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "q")
        await cache.store(standing, summary: "prefs")
        await cache.store(situational, summary: "context")
        await cache.invalidate(conversationID: convID, lane: .standing)
        #expect(await cache.fresh(standing, ttlMs: 60_000) == nil)
        #expect(await cache.fresh(situational, ttlMs: 60_000) == "context")
    }

    @Test("invalidate with nil lane removes all entries for that conversation")
    func invalidateAll() async {
        let convID = UUID()
        let otherConvID = UUID()
        let cache = ActiveMemoryRecallCache()
        let mine = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .standing, queryFingerprint: nil)
        let other = ActiveMemoryRecallCache.Key(conversationID: otherConvID, lane: .standing, queryFingerprint: nil)
        await cache.store(mine, summary: "mine")
        await cache.store(other, summary: "other")
        await cache.invalidate(conversationID: convID, lane: nil)
        #expect(await cache.fresh(mine, ttlMs: 60_000) == nil)
        #expect(await cache.fresh(other, ttlMs: 60_000) == "other")
    }
}
