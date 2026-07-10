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

    @Test("cap eviction drops LRU situational when over maxEntries")
    func capEvictsLRUSituational() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache(maxEntries: 2)
        let a = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "a")
        let b = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "b")
        let c = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "c")
        await cache.store(a, summary: "a")
        await cache.store(b, summary: "b")
        await cache.store(c, summary: "c")
        #expect(await cache.entryCount(for: convID) == 2)
        #expect(await cache.fresh(a, ttlMs: 60_000) == nil)
        #expect(await cache.fresh(b, ttlMs: 60_000) == "b")
        #expect(await cache.fresh(c, ttlMs: 60_000) == "c")
    }

    @Test("standing survives eviction when situational overflows")
    func standingStickyUnderPressure() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache(maxEntries: 2)
        let standing = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .standing, queryFingerprint: nil)
        let s1 = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "s1")
        let s2 = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "s2")
        let s3 = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "s3")
        await cache.store(standing, summary: "prefs")
        await cache.store(s1, summary: "one")
        // At cap (2). Next store must evict situational, not standing.
        await cache.store(s2, summary: "two")
        #expect(await cache.fresh(standing, ttlMs: 60_000) == "prefs")
        #expect(await cache.entryCount(for: convID) == 2)
        await cache.store(s3, summary: "three")
        #expect(await cache.fresh(standing, ttlMs: 60_000) == "prefs")
        #expect(await cache.entryCount(for: convID) == 2)
        #expect(await cache.fresh(s1, ttlMs: 60_000) == nil)
    }

    @Test("fresh touch protects a situational key from next eviction")
    func freshTouchesLRU() async {
        let convID = UUID()
        let cache = ActiveMemoryRecallCache(maxEntries: 2)
        let a = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "a")
        let b = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "b")
        let c = ActiveMemoryRecallCache.Key(conversationID: convID, lane: .situational, queryFingerprint: "c")
        await cache.store(a, summary: "a")
        await cache.store(b, summary: "b")
        // Touch a so b becomes LRU.
        #expect(await cache.fresh(a, ttlMs: 60_000) == "a")
        await cache.store(c, summary: "c")
        #expect(await cache.fresh(a, ttlMs: 60_000) == "a")
        #expect(await cache.fresh(b, ttlMs: 60_000) == nil)
        #expect(await cache.fresh(c, ttlMs: 60_000) == "c")
    }

    @Test("overflow in one conversation does not evict another")
    func perConversationIsolation() async {
        let aID = UUID()
        let bID = UUID()
        let cache = ActiveMemoryRecallCache(maxEntries: 2)
        let a1 = ActiveMemoryRecallCache.Key(conversationID: aID, lane: .situational, queryFingerprint: "1")
        let a2 = ActiveMemoryRecallCache.Key(conversationID: aID, lane: .situational, queryFingerprint: "2")
        let a3 = ActiveMemoryRecallCache.Key(conversationID: aID, lane: .situational, queryFingerprint: "3")
        let b1 = ActiveMemoryRecallCache.Key(conversationID: bID, lane: .situational, queryFingerprint: "1")
        await cache.store(b1, summary: "b-keep")
        await cache.store(a1, summary: "a1")
        await cache.store(a2, summary: "a2")
        await cache.store(a3, summary: "a3")
        #expect(await cache.fresh(b1, ttlMs: 60_000) == "b-keep")
        #expect(await cache.entryCount(for: aID) == 2)
        #expect(await cache.entryCount(for: bID) == 1)
    }

    @Test("loader clamps activeMemoryRecallCacheMaxEntries")
    func loaderClampsMaxEntries() {
        #expect(MemoryConfiguration.default.activeMemoryRecallCacheMaxEntries == 1_000)
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryRecallCacheMaxEntries": 0])
                .activeMemoryRecallCacheMaxEntries == 1
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryRecallCacheMaxEntries": -5])
                .activeMemoryRecallCacheMaxEntries == 1
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryRecallCacheMaxEntries": 1_000])
                .activeMemoryRecallCacheMaxEntries == 1_000
        )
        #expect(
            MemoryConfigurationLoader.load(fromMemoryObject: ["activeMemoryRecallCacheMaxEntries": 200_000])
                .activeMemoryRecallCacheMaxEntries == 100_000
        )
    }
}
