import Foundation

actor TriggerRateLimitGate {
    private var buckets: [String: [Date]] = [:]
    private let windowSeconds: TimeInterval
    private let maxPerWindow: Int

    init(windowSeconds: TimeInterval = 60, maxPerWindow: Int = 30) {
        self.windowSeconds = windowSeconds
        self.maxPerWindow = maxPerWindow
    }

    func isRateLimited(key: String, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var hits = (buckets[key] ?? []).filter { $0 > cutoff }
        if hits.count >= maxPerWindow {
            buckets[key] = hits
            return true
        }
        hits.append(now)
        buckets[key] = hits
        return false
    }
}
