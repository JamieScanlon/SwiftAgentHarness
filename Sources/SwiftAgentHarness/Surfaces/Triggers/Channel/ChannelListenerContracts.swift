import Foundation

public enum ChannelId: String, Sendable, Codable {
    case slack
    case telegram
    case discord
    case email
}

typealias ChannelTriggerHandler = @Sendable (HarnessTrigger) async -> Void

protocol ChannelListener: Sendable {
    var id: ChannelId { get }
    var platformIdentity: String { get }
    var state: ChannelListenerState { get }
    var fatalError: ChannelFatalError? { get }
    var config: ChannelListenerConfig { get }

    func connect() async throws -> ChannelConnectResult
    func disconnect() async
    func onTrigger(_ handler: @escaping ChannelTriggerHandler) -> @Sendable () -> Void
    func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult
    func sendTyping(chatId: String) async
    func react(messageId: String, emoji: String) async
}

protocol ChannelRawEventParsing: Sendable {
    static func parseRawEvent(_ raw: MockChannelRawEvent) -> ChannelMessageEvent?
}
