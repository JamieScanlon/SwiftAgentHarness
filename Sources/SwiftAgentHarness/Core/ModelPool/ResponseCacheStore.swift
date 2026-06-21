import Foundation
import SwiftAgentKit

public actor ResponseCacheStore {
    private struct Entry: Sendable {
        let response: LLMResponse
        var insertedAt: Date
    }

    private var entriesByKey: [ResponseCacheKey: Entry] = [:]
    private var lruOrder: [ResponseCacheKey] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func lookup(key: ResponseCacheKey, ttlSeconds: Double?) -> LLMResponse? {
        guard let entry = entriesByKey[key] else { return nil }
        if isExpired(entry: entry, ttlSeconds: ttlSeconds) {
            remove(key: key)
            return nil
        }
        touch(key: key)
        return entry.response
    }

    func insert(key: ResponseCacheKey, response: LLMResponse, maxEntries: Int, ttlSeconds: Double?) {
        guard maxEntries > 0 else { return }
        purgeExpired(ttlSeconds: ttlSeconds)
        entriesByKey[key] = Entry(response: response, insertedAt: now())
        touch(key: key)
        while entriesByKey.count > maxEntries, let oldest = lruOrder.first {
            remove(key: oldest)
        }
    }

    public func clear() {
        entriesByKey.removeAll(keepingCapacity: false)
        lruOrder.removeAll(keepingCapacity: false)
    }

    public func count() -> Int { entriesByKey.count }

    private func purgeExpired(ttlSeconds: Double?) {
        guard let ttlSeconds, ttlSeconds > 0 else { return }
        let expired = entriesByKey.compactMap { key, entry in
            isExpired(entry: entry, ttlSeconds: ttlSeconds) ? key : nil
        }
        for key in expired {
            remove(key: key)
        }
    }

    private func isExpired(entry: Entry, ttlSeconds: Double?) -> Bool {
        guard let ttlSeconds, ttlSeconds > 0 else { return false }
        return now().timeIntervalSince(entry.insertedAt) > ttlSeconds
    }

    private func touch(key: ResponseCacheKey) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func remove(key: ResponseCacheKey) {
        entriesByKey.removeValue(forKey: key)
        lruOrder.removeAll { $0 == key }
    }
}

