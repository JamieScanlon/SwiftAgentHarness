import Foundation

actor ChannelMentionGate {
    private let mentionedThreads: BoundedLRUCache<Void>
    private let config: ChannelMentionConfig

    init(config: ChannelMentionConfig, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.mentionedThreads = BoundedLRUCache(
            maxEntries: config.mentionedThreadMaxEntries,
            ttlSeconds: config.mentionedThreadTTLSeconds,
            now: now
        )
    }

    func evaluate(event: ChannelMessageEvent, canDetectMention: Bool = true) async -> ChannelMentionGateResult {
        if !event.isGroup {
            return ChannelMentionGateResult(effectiveWasMentioned: true, shouldSkip: false, shouldBypassMention: true)
        }
        if !config.requireInGroups {
            return ChannelMentionGateResult(effectiveWasMentioned: true, shouldSkip: false, shouldBypassMention: false)
        }
        var effective = event.mentionsBot || event.hasMention
        if config.implicitKinds.contains(.replyToBot), event.isReplyToBot {
            effective = true
        }
        if let threadId = event.threadId {
            let key = "\(event.chatId):\(threadId)"
            if config.implicitKinds.contains(.botThreadParticipant), await mentionedThreads.contains(key) {
                effective = true
            }
            if effective {
                await mentionedThreads.insertMarker(key: key)
            }
        }
        if !canDetectMention {
            effective = config.treatUnknownAs == .mention
        }
        return ChannelMentionGateResult(
            effectiveWasMentioned: effective,
            shouldSkip: !effective,
            shouldBypassMention: false
        )
    }
}
