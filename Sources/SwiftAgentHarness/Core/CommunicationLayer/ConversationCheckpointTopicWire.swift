//
//  UTF-8 JSON body for ``ConversationTopicEventPayload`` when ``semanticKind == .checkpoint``.
//

import Foundation

/// v1 envelope for harness **Checkpoint** class on `conversation/{id}/events`.
public struct ConversationCheckpointTopicEventWire: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public enum Variant: String, Codable, Sendable {
        case contextCompactionCheckpoint
        case checkpointInvalidation
    }

    public var schemaVersion: Int
    public var variant: Variant
    public var conversationID: UUID
    /// ``HarnessCheckpointWireKind.rawValue`` (e.g. `context_compaction`) for compaction notifications.
    public var harnessCheckpointKind: String?
    /// ``ContextCompactionCheckpointKind`` raw (`summarized` / `pruned`) when ``variant`` is compaction.
    public var compactionCheckpointKind: String?
    /// Raw middle slice ids replaced by compaction (same ordering as persistence).
    public var coveredRawMessageIDs: [SessionEntryID]?
    /// Anchor tail message id when known (optional).
    public var basedOnTailMessageID: SessionEntryID?
    /// Invalidated harness checkpoint kind strings (same vocabulary as REST invalidate body).
    public var invalidatedCheckpointKinds: [String]?

    // MARK: - README `record_compaction` fields (harness template; Gap 15)

    /// Human-readable compaction summary (README **`summary`**).
    public var summary: String?
    /// First transcript row retained after compaction (README **`first_kept_entry_id`**).
    ///
    /// Transcript node identifier (`SessionTranscriptEntry.entryId`), canonical short-hex on new writes.
    public var firstKeptEntryID: SessionEntryID?
    /// Token count before compaction (README **`tokens_before`**).
    public var tokensBefore: Int?
    /// Optional extension bag (README **`details`**).
    public var details: [String: SessionTranscriptJSONValue]?

    public init(
        schemaVersion: Int = ConversationCheckpointTopicEventWire.currentSchemaVersion,
        variant: Variant,
        conversationID: UUID,
        harnessCheckpointKind: String? = nil,
        compactionCheckpointKind: String? = nil,
        coveredRawMessageIDs: [SessionEntryID]? = nil,
        basedOnTailMessageID: SessionEntryID? = nil,
        invalidatedCheckpointKinds: [String]? = nil,
        summary: String? = nil,
        firstKeptEntryID: SessionEntryID? = nil,
        tokensBefore: Int? = nil,
        details: [String: SessionTranscriptJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.variant = variant
        self.conversationID = conversationID
        self.harnessCheckpointKind = harnessCheckpointKind
        self.compactionCheckpointKind = compactionCheckpointKind
        self.coveredRawMessageIDs = coveredRawMessageIDs
        self.basedOnTailMessageID = basedOnTailMessageID
        self.invalidatedCheckpointKinds = invalidatedCheckpointKinds
        self.summary = summary
        self.firstKeptEntryID = firstKeptEntryID
        self.tokensBefore = tokensBefore
        self.details = details
    }
}
