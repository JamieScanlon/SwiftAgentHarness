//
//  Harness runs.md: terminal semantics on the append-only transcript (`custom` rows).
//

import Foundation

/// Wire string on JSONL lines with ``SessionTranscriptEntryType/custom`` (via ``SessionTranscriptEntry/harnessTypeRaw``).
enum RunLifecycleTranscriptMarkerKind: String, Codable, Sendable {
    case run_cancelled
    case run_orphaned
    case run_errored
    case run_bounded
}

/// JSON object stored in ``SessionTranscriptEntry/payloadJSON`` for run lifecycle markers.
struct RunLifecycleTranscriptMarkerPayload: Codable, Sendable, Equatable {
    /// Same as ``RunLifecycleTranscriptMarkerKind/rawValue``; duplicated as `customType` for runs.md alignment.
    var customType: String
    var runId: UUID
    var reason: String?
    var iteration: Int?
    var createdAt: Date
    /// Optional serialized ``ConversationRunTerminalReason`` fields for REST parity.
    var terminalReasonCategory: String?
    var terminalReasonBounded: String?
    var terminalReasonDetail: String?

    init(
        kind: RunLifecycleTranscriptMarkerKind,
        runId: UUID,
        reason: String? = nil,
        iteration: Int? = nil,
        createdAt: Date = Date(),
        terminalReason: ConversationRunTerminalReason? = nil
    ) {
        self.customType = kind.rawValue
        self.runId = runId
        self.reason = reason
        self.iteration = iteration
        self.createdAt = createdAt
        if let terminalReason {
            self.terminalReasonCategory = terminalReason.category.rawValue
            self.terminalReasonBounded = terminalReason.boundedReason?.rawValue
            self.terminalReasonDetail = terminalReason.detail
        } else {
            self.terminalReasonCategory = nil
            self.terminalReasonBounded = nil
            self.terminalReasonDetail = nil
        }
    }

    func encodedJSONString() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "run lifecycle marker utf-8 encode failed")
        }
        return string
    }

    static func decode(from payloadJSON: String) throws -> RunLifecycleTranscriptMarkerPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "run lifecycle marker not utf-8")
        }
        return try JSONDecoder().decode(RunLifecycleTranscriptMarkerPayload.self, from: data)
    }

    func resolvedTerminalReason() -> ConversationRunTerminalReason? {
        guard let terminalReasonCategory,
              let category = ConversationRunTerminalCategory(rawValue: terminalReasonCategory)
        else {
            return nil
        }
        let bounded = terminalReasonBounded.flatMap { ConversationRunBoundedReason(rawValue: $0) }
        return ConversationRunTerminalReason(
            category: category,
            boundedReason: bounded,
            detail: terminalReasonDetail
        )
    }
}
