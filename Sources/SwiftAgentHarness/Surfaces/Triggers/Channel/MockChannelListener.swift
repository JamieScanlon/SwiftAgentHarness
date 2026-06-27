import Foundation
import Logging
import os

final class MockChannelListener: ChannelListener, ChannelSupervisedListening, @unchecked Sendable {
    let id: ChannelId
    let platformIdentity: String
    let config: ChannelListenerConfig
    private let transport: MockChannelTransport
    private let stateLock = OSAllocatedUnfairLock()
    private let handlerBox = HandlerBox()
    private var _state: ChannelListenerState = .disconnected
    private var _fatalError: ChannelFatalError?
    private var _sentMessages: [ChannelOutboundMessage] = []
    private var _typingChatIds: [String] = []

    var state: ChannelListenerState {
        stateLock.withLock { _state }
    }

    var fatalError: ChannelFatalError? {
        stateLock.withLock { _fatalError }
    }

    var sentMessages: [ChannelOutboundMessage] {
        stateLock.withLock { _sentMessages }
    }

    var typingChatIds: [String] {
        stateLock.withLock { _typingChatIds }
    }

    var typingCallCount: Int {
        stateLock.withLock { _typingChatIds.count }
    }

    init(id: ChannelId, config: ChannelListenerConfig, logger: Logging.Logger) {
        self.id = id
        self.config = config
        self.platformIdentity = config.platformIdentity
        self.transport = MockChannelTransport()
        _ = logger
    }

    func transportForSupervision() -> any ChannelTransport {
        transport
    }

    func markTransportConnected() {
        stateLock.withLock { _state = .connected }
    }

    func markTransportDisconnected() {
        stateLock.withLock { _state = .disconnected }
    }

    func prepareSupervisedTransport() async throws {
        try await transport.connect()
    }

    func connect() async throws -> ChannelConnectResult {
        stateLock.withLock { _state = .connecting }
        do {
            try await transport.connect()
            stateLock.withLock { _state = .connected }
            return .connected
        } catch {
            let fatal = ChannelFatalError(code: "connect_failed", message: String(describing: error), retryable: true)
            stateLock.withLock {
                _state = .fatal
                _fatalError = fatal
            }
            return .fatal(fatal)
        }
    }

    func disconnect() async {
        await transport.disconnect()
        stateLock.withLock { _state = .disconnected }
    }

    func onTrigger(_ handler: @escaping ChannelTriggerHandler) -> @Sendable () -> Void {
        let token = handlerBox.add(handler)
        return { [handlerBox] in handlerBox.remove(token: token) }
    }

    func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult {
        stateLock.withLock { _sentMessages.append(message) }
        return .sent(messageId: UUID().uuidString)
    }

    func sendTyping(chatId: String) async {
        stateLock.withLock { _typingChatIds.append(chatId) }
    }

    func react(messageId: String, emoji: String) async {}

    func transportEvents() -> AsyncStream<ChannelTransportRawEvent> {
        transport.events()
    }

    func injectRawEvent(_ raw: ChannelTransportRawEvent) {
        transport.inject(raw)
    }

    func emitTrigger(_ trigger: HarnessTrigger) async {
        for handler in handlerBox.allHandlers() {
            await handler(trigger)
        }
    }

    func setFatal(_ error: ChannelFatalError) {
        stateLock.withLock {
            _state = .fatal
            _fatalError = error
        }
    }
}

private final class HandlerBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var handlers: [UUID: ChannelTriggerHandler] = [:]

    func add(_ handler: @escaping ChannelTriggerHandler) -> UUID {
        let token = UUID()
        lock.withLock { handlers[token] = handler }
        return token
    }

    func remove(token: UUID) {
        lock.withLock { handlers[token] = nil }
    }

    func allHandlers() -> [ChannelTriggerHandler] {
        lock.withLock { Array(handlers.values) }
    }
}
