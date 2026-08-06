import Foundation

actor TriggerInitiatorBurstGate {
    private var counts: [String: (windowStart: Date, count: Int)] = [:]
    private let windowSeconds: TimeInterval
    private let maxPerWindow: Int

    init(windowSeconds: TimeInterval = 3600, maxPerWindow: Int = 120) {
        self.windowSeconds = windowSeconds
        self.maxPerWindow = maxPerWindow
    }

    func isOverBurstLimit(initiatorKey: String, now: Date = Date()) -> Bool {
        if var entry = counts[initiatorKey] {
            if now.timeIntervalSince(entry.windowStart) >= windowSeconds {
                entry = (now, 0)
            }
            if entry.count >= maxPerWindow {
                counts[initiatorKey] = entry
                return true
            }
            entry.count += 1
            counts[initiatorKey] = entry
            return false
        }
        counts[initiatorKey] = (now, 1)
        return false
    }
}
