import Foundation

typealias ChannelTriggerHandler = @Sendable (HarnessTrigger) async -> Void

protocol ChannelListener: Sendable, ChannelOutboundListening {
    var id: ChannelId { get }
    var platformIdentity: String { get }
    var state: ChannelListenerState { get }
    var fatalError: ChannelFatalError? { get }
    var config: ChannelListenerConfig { get }

    func connect() async throws -> ChannelConnectResult
    func disconnect() async
    func onTrigger(_ handler: @escaping ChannelTriggerHandler) -> @Sendable () -> Void
    func sendTyping(chatId: String) async
    func react(messageId: String, emoji: String) async
}

protocol ChannelSupervisedListening: ChannelListener {
    func prepareSupervisedTransport() async throws
    func transportForSupervision() -> any ChannelTransport
    func markTransportConnected()
    func markTransportDisconnected()
    func setFatal(_ error: ChannelFatalError)
}

protocol ChannelRawEventParsing: Sendable {
    static func parseRawEvent(_ raw: ChannelTransportRawEvent) -> ChannelMessageEvent?
}
