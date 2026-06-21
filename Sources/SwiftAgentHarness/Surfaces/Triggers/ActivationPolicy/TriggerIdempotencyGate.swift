import Foundation

protocol TriggerDedupeChecking: Sendable {
    func dedupePeek(key: String) async throws -> Bool
    func dedupeCheckAndSet(key: String, ttlSeconds: Int) async throws -> Bool
}

struct TriggerIdempotencyGate: Sendable {
    let dedupe: any TriggerDedupeChecking
    let ttlSeconds: Int

    init(dedupe: any TriggerDedupeChecking, ttlSeconds: Int = 3600) {
        self.dedupe = dedupe
        self.ttlSeconds = ttlSeconds
    }

    func peekDuplicate(triggerID: String) async throws -> Bool {
        try await dedupe.dedupePeek(key: dedupeKey(for: triggerID))
    }

    /// Returns `true` when this caller claims the idempotency slot; `false` when already claimed.
    func claimTrigger(triggerID: String) async throws -> Bool {
        try await dedupe.dedupeCheckAndSet(key: dedupeKey(for: triggerID), ttlSeconds: ttlSeconds)
    }

    func isDuplicate(triggerID: String) async throws -> Bool {
        !(try await claimTrigger(triggerID: triggerID))
    }

    private func dedupeKey(for triggerID: String) -> String {
        "trigger:\(triggerID)"
    }
}
