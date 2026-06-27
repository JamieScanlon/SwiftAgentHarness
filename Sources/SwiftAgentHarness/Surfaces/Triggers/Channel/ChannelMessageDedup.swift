import Foundation

actor ChannelMessageDedup {
    private var seen: [String: Date] = [:]
    private let ttlSeconds: TimeInterval

    init(ttlSeconds: TimeInterval = 60) {
        self.ttlSeconds = ttlSeconds
    }

    func isDuplicate(
        channel: ChannelId,
        platformMessageId: String,
        accountId: String? = nil,
        peerId: String? = nil,
        sessionKey: String? = nil,
        now: Date = Date()
    ) -> Bool {
        purge(now: now)
        let key = Self.dedupeKey(
            channel: channel,
            platformMessageId: platformMessageId,
            accountId: accountId,
            peerId: peerId,
            sessionKey: sessionKey
        )
        if seen[key] != nil { return true }
        seen[key] = now
        return false
    }

    static func dedupeKey(
        channel: ChannelId,
        platformMessageId: String,
        accountId: String?,
        peerId: String?,
        sessionKey: String?
    ) -> String {
        [
            channel.rawValue,
            accountId ?? "-",
            peerId ?? "-",
            sessionKey ?? "-",
            platformMessageId,
        ].joined(separator: ":")
    }

    private func purge(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) < ttlSeconds }
    }
}
