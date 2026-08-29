import Foundation

actor TriggerRateLimitGate {
    private var buckets: [String: [Date]] = [:]
    private let windowSeconds: TimeInterval
    private let maxPerWindow: Int

    init(windowSeconds: TimeInterval = 60, maxPerWindow: Int = 30) {
        self.windowSeconds = windowSeconds
        self.maxPerWindow = maxPerWindow
    }

    /// `limit` overrides the gate default for this key — that is how a webhook route's
    /// `rateLimitPerMin` reaches the gate. It was a declared field with no wiring until now.
    func isRateLimited(key: String, limit: Int? = nil, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let effectiveLimit = limit.map { max(1, $0) } ?? maxPerWindow
        var hits = (buckets[key] ?? []).filter { $0 > cutoff }
        if hits.count >= effectiveLimit {
            buckets[key] = hits
            return true
        }
        hits.append(now)
        buckets[key] = hits
        return false
    }
}
