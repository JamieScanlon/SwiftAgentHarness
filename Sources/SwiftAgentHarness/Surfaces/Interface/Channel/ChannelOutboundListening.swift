import Foundation

/// Minimal outbound wire port used by surface adapters to deliver rendered payloads.
public protocol ChannelOutboundListening: Sendable {
    func send(_ message: ChannelOutboundMessage) async -> ChannelSendResult
}
