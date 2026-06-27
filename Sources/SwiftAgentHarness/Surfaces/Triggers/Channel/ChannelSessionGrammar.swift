import Foundation

struct ChannelSessionGrammar: ChannelSessionGrammarAdapting {
    func resolveSessionConversation(raw: ChannelSessionRawIdentity) -> ChannelSessionConversationResolution {
        Self.resolve(raw: raw, config: nil)
    }

    static func resolve(
        event: ChannelMessageEvent,
        config: ChannelListenerConfig
    ) -> ChannelSessionConversationResolution {
        let raw = ChannelSessionRawIdentity(
            channel: event.channel,
            accountId: config.platformIdentity,
            chatId: event.chatId,
            threadId: event.threadId,
            senderId: event.senderId,
            platformMessageId: event.platformMessageId
        )
        return resolve(raw: raw, config: config)
    }

    static func resolve(
        raw: ChannelSessionRawIdentity,
        config: ChannelListenerConfig?
    ) -> ChannelSessionConversationResolution {
        let config = config ?? ChannelListenerConfig(platformIdentity: raw.accountId)
        let baseKey = ChannelSessionScopeResolver.resolveSessionKey(
            event: ChannelMessageEvent(
                channel: raw.channel,
                platformMessageId: raw.platformMessageId,
                senderId: raw.senderId,
                chatId: raw.chatId,
                threadId: raw.threadId,
                receivedAt: 0,
                type: .text,
                text: "",
                attachments: [],
                isReplyToBot: false,
                hasMention: false,
                mentionsBot: false,
                isDirect: false,
                isGroup: false,
                chatTypeRaw: "unknown",
                internalEvent: false
            ),
            config: config
        )
        var fallbacks: [String] = []
        if let threadId = raw.threadId, !threadId.isEmpty {
            let withoutThread = baseKey.replacingOccurrences(of: ":\(threadId)", with: "")
            if withoutThread != baseKey {
                fallbacks.append(withoutThread)
            }
        }
        let channelPeerBase = "channel:\(raw.channel.rawValue):\(raw.senderId)"
        if !fallbacks.contains(channelPeerBase) {
            fallbacks.append(channelPeerBase)
        }
        let accountPeerBase = "channel:\(raw.accountId):\(raw.channel.rawValue):\(raw.senderId)"
        if !fallbacks.contains(accountPeerBase) {
            fallbacks.append(accountPeerBase)
        }
        return ChannelSessionConversationResolution(
            baseConversationKey: baseKey,
            threadId: raw.threadId,
            parentFallbackCandidates: fallbacks
        )
    }

    /// Bootstrap-safe session key parsing for read-only status/list commands.
    static func bootstrapResolveSessionKey(
        channel: ChannelId,
        chatId: String,
        threadId: String?,
        senderId: String,
        platformIdentity: String
    ) -> String {
        let event = ChannelMessageEvent(
            channel: channel,
            platformMessageId: "bootstrap",
            senderId: senderId,
            chatId: chatId,
            threadId: threadId,
            receivedAt: 0,
            type: .text,
            text: "",
            attachments: [],
            isReplyToBot: false,
            hasMention: false,
            mentionsBot: false,
            isDirect: true,
            isGroup: false,
            chatTypeRaw: "dm",
            internalEvent: true
        )
        let config = ChannelListenerConfig(
            platformIdentity: platformIdentity,
            dmScope: .perChannelPeer
        )
        return ChannelSessionScopeResolver.resolveSessionKey(event: event, config: config)
    }
}
