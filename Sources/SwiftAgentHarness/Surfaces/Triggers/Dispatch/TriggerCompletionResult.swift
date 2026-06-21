import Foundation

enum TriggerCompletionStatus: String, Codable, Sendable, Equatable {
    case completed
    case failed
    case timedOut = "timed-out"
    case unknown
}

struct TriggerCompletionResult: Sendable, Equatable {
    var status: TriggerCompletionStatus
    var text: String
    var childSessionID: UUID
    var announceID: String?
}

enum TriggerCompletionSuppressReason: Sendable, Equatable {
    case announceSkip
    case noReply
}

enum TriggerCompletionTextPolicy {
    static let announceSkip = "ANNOUNCE_SKIP"
    static let noReplyMarkers: Set<String> = ["NO_REPLY", "no_reply"]

    static func normalizedAssistantText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func suppressReason(for text: String) -> TriggerCompletionSuppressReason? {
        let trimmed = normalizedAssistantText(text)
        if trimmed == announceSkip {
            return .announceSkip
        }
        if noReplyMarkers.contains(trimmed) {
            return .noReply
        }
        return nil
    }
}
