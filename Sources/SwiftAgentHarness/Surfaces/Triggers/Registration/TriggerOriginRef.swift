import Foundation

/// Where a trigger's output should be announced back to.
///
/// Captured at *create* time from the registering session's environment, because at fire time there
/// is no live session to ask. A cron job created from a Telegram thread must be able to answer into
/// that thread months later.
///
/// `channel` holds a `ChannelId` raw value rather than the enum so the record stays decodable across
/// channel-vocabulary changes.
public struct TriggerOriginRef: Codable, Sendable, Equatable {
    public var channel: String?
    public var chatID: String?
    public var threadID: String?
    public var accountID: String?
    /// The in-harness conversation that registered the trigger, when the origin is the app itself.
    public var conversationID: UUID?

    public init(
        channel: String? = nil,
        chatID: String? = nil,
        threadID: String? = nil,
        accountID: String? = nil,
        conversationID: UUID? = nil
    ) {
        self.channel = channel
        self.chatID = chatID
        self.threadID = threadID
        self.accountID = accountID
        self.conversationID = conversationID
    }

    public var isEmpty: Bool {
        channel == nil && chatID == nil && threadID == nil && accountID == nil && conversationID == nil
    }

    /// Normalized to `nil` when nothing was captured, so an empty record never reaches the store.
    public var normalized: TriggerOriginRef? {
        isEmpty ? nil : self
    }
}
