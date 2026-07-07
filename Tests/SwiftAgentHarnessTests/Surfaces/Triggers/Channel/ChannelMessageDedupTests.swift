import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

actor InMemoryTriggerDedupe: TriggerDedupeChecking {
    private var seen: [String: (expiresAt: Date, insertedAt: Date)] = [:]

    func dedupePeek(key: String) async throws -> Bool {
        purgeExpired(now: Date())
        guard let entry = seen[key] else { return false }
        return entry.expiresAt >= Date()
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        let now = Date()
        purgeExpired(now: now)
        if let entry = seen[key], entry.expiresAt >= now {
            return false
        }
        seen[key] = (expiresAt: now.addingTimeInterval(TimeInterval(ttlSeconds)), insertedAt: now)
        return true
    }

    private func purgeExpired(now: Date) {
        seen = seen.filter { $0.value.expiresAt >= now }
    }
}

struct SessionDedupeStoreAdapter: TriggerDedupeChecking, @unchecked Sendable {
    let store: SessionDedupeSQLiteStore

    func dedupePeek(key: String) async throws -> Bool {
        try store.dedupePeek(key: key)
    }

    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool {
        try store.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
    }
}

@Suite("ChannelMessageDedup")
struct ChannelMessageDedupTests {
    @Test("repeat id dropped within TTL")
    func repeatDropped() async {
        let dedup = ChannelMessageDedup(dedupe: InMemoryTriggerDedupe(), ttlSeconds: 3600)
        let first = await dedup.isDuplicate(channel: .slack, platformMessageId: "m1")
        let second = await dedup.isDuplicate(channel: .slack, platformMessageId: "m1")
        #expect(first == false)
        #expect(second == true)
    }

    @Test("persistence key is namespaced")
    func persistenceKeyPrefix() {
        let key = ChannelMessageDedup.persistenceKey(
            channel: .slack,
            platformMessageId: "m1",
            accountId: "acct",
            peerId: "peer",
            sessionKey: "session"
        )
        #expect(key.hasPrefix("channel-intake:"))
        #expect(key.contains("slack"))
        #expect(key.contains("m1"))
    }

    @Test("survives restart when backed by sqlite store")
    func restartSurvival() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dedupe.sqlite")
        var store = try SessionDedupeSQLiteStore(fileURL: url)
        let dedup1 = ChannelMessageDedup(dedupe: SessionDedupeStoreAdapter(store: store), ttlSeconds: 3600)
        let first = await dedup1.isDuplicate(channel: .slack, platformMessageId: "restart-m1")
        #expect(first == false)
        store = try SessionDedupeSQLiteStore(fileURL: url)
        let dedup2 = ChannelMessageDedup(dedupe: SessionDedupeStoreAdapter(store: store), ttlSeconds: 3600)
        let second = await dedup2.isDuplicate(channel: .slack, platformMessageId: "restart-m1")
        #expect(second == true)
    }

    @Test("expired keys are not treated as duplicates")
    func ttlExpiry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SessionDedupeSQLiteStore(fileURL: dir.appendingPathComponent("dedupe.sqlite"))
        let key = ChannelMessageDedup.persistenceKey(
            channel: .slack,
            platformMessageId: "expire-m1",
            accountId: nil,
            peerId: nil,
            sessionKey: nil
        )
        #expect(try store.dedupeCheckAndSet(key: key, ttlSeconds: 60) == true)
        #expect(try store.dedupeCheckAndSet(key: key, ttlSeconds: 60) == false)
        #expect(try store.dedupeCheckAndSet(key: key, ttlSeconds: 60, now: Date().addingTimeInterval(4000)) == true)
    }
}
