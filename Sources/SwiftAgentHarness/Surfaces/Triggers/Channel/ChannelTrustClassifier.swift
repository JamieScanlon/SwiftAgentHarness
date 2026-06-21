import Foundation

enum ChannelTrustClassifier {
    static func classify(event: ChannelMessageEvent, config: ChannelListenerConfig, effectiveWasMentioned: Bool) -> CommEnvelopeOriginTrust {
        if event.internalEvent { return .system }
        if event.isDirect, event.senderId == config.primaryUser { return .userDirect }
        let allowlist = event.isDirect ? config.auth.dmAllowFrom : effectiveGroupAllowlist(config: config)
        if allowlist.contains(event.senderId) {
            return .knownParty
        }
        if event.isGroup, effectiveWasMentioned, allowlist.contains("*") {
            return .unknownParty
        }
        if event.isDirect, allowlist.contains("*") {
            return .knownParty
        }
        return .unknownParty
    }

    private static func effectiveGroupAllowlist(config: ChannelListenerConfig) -> [String] {
        if !config.auth.groupAllowFrom.isEmpty { return config.auth.groupAllowFrom }
        if config.auth.fallbackGroupToDM { return config.auth.dmAllowFrom }
        return []
    }
}
