import Foundation
import Logging

struct ChannelMessageDedup: Sendable {
    private let dedupe: any TriggerDedupeChecking
    private let ttlSeconds: Int
    private let logger: Logger

    init(
        dedupe: any TriggerDedupeChecking,
        ttlSeconds: Int = 3600,
        logger: Logger = Logger(label: "channel-dedup")
    ) {
        self.dedupe = dedupe
        self.ttlSeconds = ttlSeconds
        self.logger = logger
    }

    func isDuplicate(
        channel: ChannelId,
        platformMessageId: String,
        accountId: String? = nil,
        peerId: String? = nil,
        sessionKey: String? = nil
    ) async -> Bool {
        let key = Self.persistenceKey(
            channel: channel,
            platformMessageId: platformMessageId,
            accountId: accountId,
            peerId: peerId,
            sessionKey: sessionKey
        )
        do {
            let firstSighting = try await dedupe.dedupeCheckAndSet(key: key, ttlSeconds: ttlSeconds)
            return !firstSighting
        } catch {
            logger.warning("channel_intake_dedupe_error key=\(key) error=\(String(describing: error))")
            return false
        }
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

    static func persistenceKey(
        channel: ChannelId,
        platformMessageId: String,
        accountId: String?,
        peerId: String?,
        sessionKey: String?
    ) -> String {
        "channel-intake:" + dedupeKey(
            channel: channel,
            platformMessageId: platformMessageId,
            accountId: accountId,
            peerId: peerId,
            sessionKey: sessionKey
        )
    }
}
