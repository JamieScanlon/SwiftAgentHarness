import Foundation

actor BoundedLRUCache<Value: Sendable> {
    private struct Entry {
        var value: Value
        var insertedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var lruOrder: [String] = []
    private let maxEntries: Int
    private let ttlSeconds: TimeInterval?
    private let now: @Sendable () -> Date

    init(
        maxEntries: Int,
        ttlSeconds: TimeInterval? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxEntries = max(0, maxEntries)
        self.ttlSeconds = ttlSeconds
        self.now = now
    }

    func contains(_ key: String) -> Bool {
        guard let entry = entries[key] else { return false }
        if isExpired(entry) {
            remove(key: key)
            return false
        }
        touch(key: key)
        return true
    }

    func value(for key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        if isExpired(entry) {
            remove(key: key)
            return nil
        }
        touch(key: key)
        return entry.value
    }

    func insert(key: String, value: Value) {
        guard maxEntries > 0 else { return }
        purgeExpired()
        entries[key] = Entry(value: value, insertedAt: now())
        touch(key: key)
        while entries.count > maxEntries, let oldest = lruOrder.first {
            remove(key: oldest)
        }
    }

    func insertMarker(key: String) where Value == Void {
        insert(key: key, value: ())
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        lruOrder.removeAll(keepingCapacity: false)
    }

    func count() -> Int { entries.count }

    private func purgeExpired() {
        guard ttlSeconds != nil else { return }
        let expired = entries.compactMap { key, entry in
            isExpired(entry) ? key : nil
        }
        for key in expired {
            remove(key: key)
        }
    }

    private func isExpired(_ entry: Entry) -> Bool {
        guard let ttlSeconds, ttlSeconds > 0 else { return false }
        return now().timeIntervalSince(entry.insertedAt) > ttlSeconds
    }

    private func touch(key: String) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func remove(key: String) {
        entries.removeValue(forKey: key)
        lruOrder.removeAll { $0 == key }
    }
}

enum BoundedLRUCacheDefaults {
    static let mentionedThreadMaxEntries = 4096
    static let mentionedThreadTTLSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let isolatedSessionMaxEntries = 8192
}
