import Foundation

/// One channel's configured-and-overlay state, as the operator CLI reports it.
///
/// Deliberately carries no `running` column. The CLI is a separate process from any gateway, so it
/// cannot know whether a listener is attached; a column it would have to guess at is worse than a
/// pointer to `channel-status/<channel>.json`, which the running process writes.
struct TriggerChannelStatusRow: Codable, Sendable, Equatable {
    var channel: String
    /// Present in `channels.json` at all.
    var configured: Bool
    var configEnabled: Bool
    var runtimePaused: Bool
    var effectiveEnabled: Bool
    /// Creator *class* of the last lifecycle change — never the identity. Same redaction as
    /// `ChannelRuntimeStateView`.
    var pausedBy: String?
}

struct TriggerChannelStatusResult: Codable, Sendable, Equatable {
    var channels: [TriggerChannelStatusRow]
}

struct TriggerChannelLifecycleResult: Codable, Sendable, Equatable {
    var channel: String
    var disabled: Bool
    /// False from the CLI, always: it holds no live registry. Reported rather than hidden so the
    /// output cannot read as "the listener stopped" when only the overlay changed.
    var appliedToRunningProcess: Bool
    var message: String
}
