import Foundation

actor ActiveMemoryRecallCache {
    struct Key: Hashable, Sendable {
        let conversationID: UUID
        let lane: RecallLane
        /// nil for standing (query-independent); normalized query string for situational.
        let queryFingerprint: String?
    }

    private struct Entry {
        let summary: String
        let storedAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<String?, Never>] = [:]
    /// Least-recently-used at the front; most-recently-used at the back.
    private var lruOrder: [Key] = []
    private let maxEntries: Int

    init(maxEntries: Int = MemoryConfiguration.default.activeMemoryRecallCacheMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    func fresh(_ key: Key, ttlMs: Int) -> String? {
        guard let entry = entries[key] else { return nil }
        let ageMs = Date().timeIntervalSince(entry.storedAt) * 1000
        guard ageMs < Double(ttlMs) else {
            removeEntry(key)
            return nil
        }
        touch(key)
        return entry.summary
    }

    func store(_ key: Key, summary: String?) {
        inFlight.removeValue(forKey: key)
        if let summary {
            entries[key] = Entry(summary: summary, storedAt: Date())
            touch(key)
            evictIfNeeded(conversationID: key.conversationID)
        } else {
            removeEntry(key)
        }
    }

    func existingInFlight(_ key: Key) -> Task<String?, Never>? {
        inFlight[key]
    }

    func setInFlight(_ key: Key, task: Task<String?, Never>) {
        inFlight[key] = task
    }

    func invalidate(conversationID: UUID, lane: RecallLane?) {
        if let lane {
            cancelInFlight(matching: { $0.conversationID == conversationID && $0.lane == lane })
            let doomed = entries.keys.filter { $0.conversationID == conversationID && $0.lane == lane }
            for key in doomed {
                removeEntry(key)
            }
            inFlight = inFlight.filter { $0.key.conversationID != conversationID || $0.key.lane != lane }
        } else {
            cancelInFlight(matching: { $0.conversationID == conversationID })
            let doomed = entries.keys.filter { $0.conversationID == conversationID }
            for key in doomed {
                removeEntry(key)
            }
            inFlight = inFlight.filter { $0.key.conversationID != conversationID }
        }
    }

    /// Test/observability helper: entry count for one conversation.
    func entryCount(for conversationID: UUID) -> Int {
        entries.keys.filter { $0.conversationID == conversationID }.count
    }

    private func cancelInFlight(matching predicate: (Key) -> Bool) {
        for (key, task) in inFlight where predicate(key) {
            task.cancel()
        }
    }

    private func touch(_ key: Key) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    private func removeEntry(_ key: Key) {
        entries.removeValue(forKey: key)
        lruOrder.removeAll { $0 == key }
    }

    private func evictIfNeeded(conversationID: UUID) {
        while entryCount(for: conversationID) > maxEntries {
            guard let victim = nextEvictionVictim(conversationID: conversationID) else { break }
            removeEntry(victim)
        }
    }

    /// Prefer least-recently-used situational keys; never drop standing while situational exists.
    private func nextEvictionVictim(conversationID: UUID) -> Key? {
        if let situational = lruOrder.first(where: {
            $0.conversationID == conversationID && $0.lane == .situational
        }) {
            return situational
        }
        return lruOrder.first(where: { $0.conversationID == conversationID })
    }
}
