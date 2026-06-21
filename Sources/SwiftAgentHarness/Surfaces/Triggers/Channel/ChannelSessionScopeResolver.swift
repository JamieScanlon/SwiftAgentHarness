import Foundation

enum ChannelSessionScopeResolver {
    static func resolveSessionKey(event: ChannelMessageEvent, config: ChannelListenerConfig) -> String {
        let sender = canonicalSender(channel: event.channel, senderId: event.senderId, identityLinks: config.identityLinks)
        let channel = event.channel.rawValue
        let base: String
        switch config.dmScope {
        case .main:
            base = "channel:main"
        case .perPeer:
            base = "channel:peer:\(sender)"
        case .perChannelPeer:
            base = "channel:\(channel):\(sender)"
        case .perAccountChannelPeer:
            base = "channel:\(config.platformIdentity):\(channel):\(sender)"
        }
        if let threadId = event.threadId, !threadId.isEmpty {
            return "\(base):\(threadId)"
        }
        return base
    }

    private static func canonicalSender(channel: ChannelId, senderId: String, identityLinks: [String: String]) -> String {
        identityLinks["\(channel.rawValue):\(senderId)"] ?? senderId
    }
}
