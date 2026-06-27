import Foundation

/// Session grammar slot: resolve native ids to session keys and parent fallbacks.
protocol ChannelSessionGrammarAdapting: Sendable {
    func resolveDedupSessionKey(event: ChannelMessageEvent, config: ChannelListenerConfig) -> String
    func resolveSessionConversation(raw: ChannelSessionRawIdentity) -> ChannelSessionConversationResolution
}

struct ChannelSessionRawIdentity: Sendable, Equatable {
    var channel: ChannelId
    var accountId: String
    var chatId: String
    var threadId: String?
    var senderId: String
    var platformMessageId: String
}

struct ChannelSessionConversationResolution: Sendable, Equatable {
    var baseConversationKey: String
    var threadId: String?
    var parentFallbackCandidates: [String]
}

/// Security slot: inbound trust, allowlists, mention gating helpers.
protocol ChannelSecurityAdapting: Sendable {
    func isAllowed(event: ChannelMessageEvent, config: ChannelListenerConfig) -> Bool
    func makeMentionGate(config: ChannelMentionConfig) -> ChannelMentionGate
    func classifyTrust(
        event: ChannelMessageEvent,
        config: ChannelListenerConfig,
        effectiveWasMentioned: Bool
    ) -> CommEnvelopeOriginTrust
    func redactLogIdentifier(_ value: String) -> String
}

typealias ChannelPluginMeta = ChannelSurfaceMeta

extension ChannelSurfaceMeta {
    init(platformIdentity: String, transportKind: ChannelTransportKind) {
        self.init(platformIdentity: platformIdentity, transportKindRaw: transportKind.rawValue)
    }
}
