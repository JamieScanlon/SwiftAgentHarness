import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("BoundedLRUCache")
struct BoundedLRUCacheTests {
    @Test("evicts oldest entry when max entries exceeded")
    func lruEviction() async {
        let cache = BoundedLRUCache<Void>(maxEntries: 2)
        await cache.insertMarker(key: "a")
        await cache.insertMarker(key: "b")
        await cache.insertMarker(key: "c")
        #expect(await cache.contains("a") == false)
        #expect(await cache.contains("b") == true)
        #expect(await cache.contains("c") == true)
    }

    @Test("ttl expiry removes stale entries")
    func ttlExpiry() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = OSAllocatedUnfairLock(initialState: start)
        let cache = BoundedLRUCache<Void>(
            maxEntries: 10,
            ttlSeconds: 60,
            now: { now.withLock { $0 } }
        )
        await cache.insertMarker(key: "thread-1")
        now.withLock { $0 = start.addingTimeInterval(61) }
        #expect(await cache.contains("thread-1") == false)
    }

    @Test("stores and retrieves typed values")
    func typedValues() async {
        let id = UUID()
        let cache = BoundedLRUCache<UUID>(maxEntries: 4)
        await cache.insert(key: "session", value: id)
        #expect(await cache.value(for: "session") == id)
    }
}
