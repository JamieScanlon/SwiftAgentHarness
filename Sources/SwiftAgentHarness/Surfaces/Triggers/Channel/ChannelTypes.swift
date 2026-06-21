import Foundation

enum ChannelListenerState: String, Codable, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case fatal
}

struct ChannelFatalError: Codable, Sendable, Equatable {
    var code: String
    var message: String
    var retryable: Bool
}

enum ChannelConnectResult: Sendable, Equatable {
    case connected
    case retryableFailure(String)
    case fatal(ChannelFatalError)
}

enum ChannelMessageType: String, Codable, Sendable, Equatable {
    case text
    case photo
    case video
    case audio
    case voice
    case document
    case sticker
    case location
    case command
    case reaction
}

struct ChannelAttachment: Codable, Sendable, Equatable {
    var filename: String
    var mimeType: String?
    var localPath: String?
    var sizeBytes: Int64?
}

struct ChannelReplyTo: Codable, Sendable, Equatable {
    var messageId: String
    var text: String?
}

struct ChannelMessageEvent: Codable, Sendable, Equatable {
    var channel: ChannelId
    var platformMessageId: String
    var platformUpdateId: String?
    var senderId: String
    var chatId: String
    var threadId: String?
    var receivedAt: Int64
    var type: ChannelMessageType
    var text: String
    var attachments: [ChannelAttachment]
    var replyToMessageId: String?
    var replyToText: String?
    var isReplyToBot: Bool
    var hasMention: Bool
    var mentionsBot: Bool
    var isDirect: Bool
    var isGroup: Bool
    var chatTypeRaw: String
    var channelPrompt: String?
    var autoSkill: String?
    var internalEvent: Bool
}

struct ChannelTriggerPayload: Codable, Sendable, Equatable {
    var text: String
    var attachments: [ChannelAttachment]
    var replyTo: ChannelReplyTo?
}

enum ChannelIntakeDropReason: String, Sendable, Equatable {
    case parseRejected
    case dedupHit
    case authDenied
    case mentionSkipped
    case debounceHeld
}

enum ChannelIntakeOutcome: Sendable, Equatable {
    case emit(HarnessTrigger)
    case drop(ChannelIntakeDropReason)
    case holdForDebounce
}

struct ChannelIntakeCounters: Codable, Sendable, Equatable {
    var parsed: Int = 0
    var dedupDropped: Int = 0
    var authDenied: Int = 0
    var mentionSkipped: Int = 0
    var debounceHeld: Int = 0
    var emitted: Int = 0
}

struct ChannelMentionGateResult: Sendable, Equatable {
    var effectiveWasMentioned: Bool
    var shouldSkip: Bool
    var shouldBypassMention: Bool
}

enum ChannelImplicitMentionKind: String, Codable, Sendable, Equatable {
    case replyToBot = "reply_to_bot"
    case quotedBot = "quoted_bot"
    case botThreadParticipant = "bot_thread_participant"
    case native
}

enum ChannelTreatUnknownMentionAs: String, Codable, Sendable, Equatable {
    case mention
    case noMention = "no-mention"
}

struct ChannelDebounceBurstMetadata: Codable, Sendable, Equatable {
    var messageIds: [String]
    var firstAt: Int64
    var lastAt: Int64
}
