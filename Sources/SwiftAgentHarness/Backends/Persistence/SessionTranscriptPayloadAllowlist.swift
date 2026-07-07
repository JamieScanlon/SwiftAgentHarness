//
//  Structured validation for auxiliary transcript rows (compaction checkpoint wire, branch summary).
//

import Foundation

enum SessionTranscriptPayloadAllowlist {
    /// Allowed top-level keys for ``SessionTranscriptMapping`` message rows (`MessageTranscriptPayload`).
    static let messageTranscriptJSONKeyAllowlist: Set<String> = [
        "v",
        "id",
        "role",
        "content",
        "timestamp",
        "toolCallId",
        "toolCallNames",
        "toolCalls",
        "attachmentRefs",
        "transcriptRunID",
        "inputTrustRaw",
        "finishReason",
        "responseFormat",
        "contentBlocks",
    ]

    /// Allowed top-level keys for ``RunLifecycleTranscriptMarkerPayload`` (`custom` transcript rows).
    static let runLifecycleMarkerJSONKeyAllowlist: Set<String> = [
        "customType",
        "runId",
        "reason",
        "iteration",
        "createdAt",
        "terminalReasonCategory",
        "terminalReasonBounded",
        "terminalReasonDetail",
    ]

    static func assertRunLifecycleMarkerPayloadAllowed(_ payloadJSON: String) throws {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "run lifecycle marker payload is not a JSON object")
        }
        let keys = Set(obj.keys)
        guard keys.isSubset(of: runLifecycleMarkerJSONKeyAllowlist) else {
            let extra = keys.subtracting(runLifecycleMarkerJSONKeyAllowlist)
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "unknown run lifecycle marker keys: \(extra.sorted())")
        }
    }

    static func assertMessagePayloadKeysAllowed(_ payloadJSON: String) throws {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "message payload is not a JSON object")
        }
        let keys = Set(obj.keys)
        guard keys.isSubset(of: messageTranscriptJSONKeyAllowlist) else {
            let extra = keys.subtracting(messageTranscriptJSONKeyAllowlist)
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "unknown message payload keys: \(extra.sorted())")
        }
    }

    static func decodeCompactionCheckpointPayload(_ payloadJSON: String) throws -> ConversationCheckpointTopicEventWire {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "compaction payload not utf-8")
        }
        do {
            return try JSONDecoder().decode(ConversationCheckpointTopicEventWire.self, from: data)
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "compaction payload decode failed")
        }
    }

    static func decodeBranchSummaryPayload(_ payloadJSON: String) throws -> SessionBranchSummaryTranscriptPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "branch summary payload not utf-8")
        }
        do {
            return try JSONDecoder().decode(SessionBranchSummaryTranscriptPayload.self, from: data)
        } catch {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "branch summary payload decode failed")
        }
    }

    static func decodeTranscriptJournalEnvelope(_ payloadJSON: String) throws -> SessionTranscriptJournalEnvelope {
        try SessionTranscriptJournalEnvelopeCodec.decode(payloadJSON)
    }
}

/// Durable shape for `branch_summary` rows; optional keys stay backward-compatible with older writers.
public struct SessionBranchSummaryTranscriptPayload: Codable, Sendable, Equatable {
    public var version: Int
    public var summary: String
    /// README **`from_entry_id`** — transcript ``SessionTranscriptEntry/entryId``.
    public var fromEntryID: SessionEntryID?
    /// README **`details`**.
    public var details: [String: SessionTranscriptJSONValue]?

    public init(
        version: Int,
        summary: String,
        fromEntryID: SessionEntryID? = nil,
        details: [String: SessionTranscriptJSONValue]? = nil
    ) {
        self.version = version
        self.summary = summary
        self.fromEntryID = fromEntryID
        self.details = details
    }
}
