import Foundation

struct MockChannelRawEvent: Sendable, Equatable {
    var channel: ChannelId
    var platformMessageId: String
    var senderId: String
    var chatId: String
    var threadId: String?
    var text: String
    var type: ChannelMessageType
    var isDirect: Bool
    var isGroup: Bool
    var mentionsBot: Bool
    var isReplyToBot: Bool
    var internalEvent: Bool
}

protocol ChannelTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func events() -> AsyncStream<MockChannelRawEvent>
}
