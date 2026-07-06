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

    func fresh(_ key: Key, ttlMs: Int) -> String? {
        guard let entry = entries[key] else { return nil }
        let ageMs = Date().timeIntervalSince(entry.storedAt) * 1000
        guard ageMs < Double(ttlMs) else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.summary
    }

    func store(_ key: Key, summary: String?) {
        inFlight.removeValue(forKey: key)
        if let summary {
            entries[key] = Entry(summary: summary, storedAt: Date())
        } else {
            entries.removeValue(forKey: key)
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
            entries = entries.filter { $0.key.conversationID != conversationID || $0.key.lane != lane }
            inFlight = inFlight.filter { $0.key.conversationID != conversationID || $0.key.lane != lane }
        } else {
            cancelInFlight(matching: { $0.conversationID == conversationID })
            entries = entries.filter { $0.key.conversationID != conversationID }
            inFlight = inFlight.filter { $0.key.conversationID != conversationID }
        }
    }

    private func cancelInFlight(matching predicate: (Key) -> Bool) {
        for (key, task) in inFlight where predicate(key) {
            task.cancel()
        }
    }
}
