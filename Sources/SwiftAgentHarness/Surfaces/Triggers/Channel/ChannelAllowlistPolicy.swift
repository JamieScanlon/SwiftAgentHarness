import Foundation

enum ChannelAllowlistPolicy {
    static func isAllowed(event: ChannelMessageEvent, config: ChannelListenerConfig) -> Bool {
        if event.internalEvent { return true }
        let allowlist = effectiveAllowlist(event: event, config: config)
        if allowlist.isEmpty { return false }
        if allowlist.contains("*") { return true }
        return allowlist.contains(event.senderId)
    }

    private static func effectiveAllowlist(event: ChannelMessageEvent, config: ChannelListenerConfig) -> [String] {
        if event.isDirect {
            return config.auth.dmAllowFrom
        }
        if !config.auth.groupAllowFrom.isEmpty {
            return config.auth.groupAllowFrom
        }
        if config.auth.fallbackGroupToDM {
            return config.auth.dmAllowFrom
        }
        return []
    }
}
