import Foundation

enum MockChannelEventParser: ChannelRawEventParsing {
    static func parseRawEvent(_ raw: MockChannelRawEvent) -> ChannelMessageEvent? {
        guard !raw.text.isEmpty || raw.type != .text else { return nil }
        return ChannelMessageEvent(
            channel: raw.channel,
            platformMessageId: raw.platformMessageId,
            senderId: raw.senderId,
            chatId: raw.chatId,
            threadId: raw.threadId,
            receivedAt: Int64(Date().timeIntervalSince1970 * 1000),
            type: raw.type,
            text: raw.text,
            attachments: [],
            isReplyToBot: raw.isReplyToBot,
            hasMention: raw.mentionsBot,
            mentionsBot: raw.mentionsBot,
            isDirect: raw.isDirect,
            isGroup: raw.isGroup,
            chatTypeRaw: raw.isDirect ? "dm" : "group",
            internalEvent: raw.internalEvent
        )
    }
}
