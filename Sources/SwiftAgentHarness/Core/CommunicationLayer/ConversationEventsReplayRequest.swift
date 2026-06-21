import Foundation

/// How a client asked to replay `conversation/{id}/events` on subscribe.
public enum ConversationEventsReplayRequest: Sendable {
    /// Single total-order cursor (`since`), replays buffered `event` lines by `seq`.
    case totalOrderSince(Int?)
    /// Dual cursors (`nil` means skip replay for that stream). Mutually exclusive with single `since` on the wire.
    case dual(sinceMessage: Int?, sinceCheckpoint: Int?)
}
