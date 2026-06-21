import Foundation

actor ChannelMessageDedup {
    private var seen: [String: Date] = [:]
    private let ttlSeconds: TimeInterval

    init(ttlSeconds: TimeInterval = 60) {
        self.ttlSeconds = ttlSeconds
    }

    func isDuplicate(channel: ChannelId, platformMessageId: String, now: Date = Date()) -> Bool {
        purge(now: now)
        let key = "\(channel.rawValue):\(platformMessageId)"
        if seen[key] != nil { return true }
        seen[key] = now
        return false
    }

    private func purge(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) < ttlSeconds }
    }
}
