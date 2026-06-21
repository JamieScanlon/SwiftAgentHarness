//
//  Persisted on ``CachedConversationEvent`` (raw markers vs derived artifacts).
//

import Foundation

/// Logical partition of the conversation journal event log.
///
/// `ConversationJournalStream` separates persisted events into two ordered streams:
/// - `raw`: durable transcript-shaping markers that represent user/assistant timeline progression.
/// - `derived`: computed or projected artifacts produced from raw timeline state.
///
/// The stream value is stored as ``CachedConversationEvent.journalStreamRaw`` and is used by
/// persistence, projection, and per-stream sequence bookkeeping to keep raw and derived ordering
/// independent while preserving a shared global `eventID`.
public enum ConversationJournalStream: String, Sendable, Codable {
    /// Durable transcript progression markers.
    case raw
    /// Computed/projection artifacts derived from raw timeline state.
    case derived

    /// Classifies a persisted event kind string into a journal stream.
    ///
    /// Use this initializer when only ``CachedConversationEvent.kind`` is available and
    /// ``CachedConversationEvent.journalStreamRaw`` is absent or needs to be derived.
    ///
    /// Kinds that represent transcript progression map to ``raw`` (`message_appended`,
    /// `interaction_mode_changed`). All other kinds map to ``derived``.
    ///
    /// - Parameter kind: Persisted event kind string from ``CachedConversationEvent.kind``.
    public init(persistedEventKind kind: String) {
        if kind == "message_appended" || kind == "interaction_mode_changed" {
            self = .raw
        } else {
            self = .derived
        }
    }
}
