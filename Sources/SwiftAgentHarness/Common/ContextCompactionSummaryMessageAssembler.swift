import Foundation
import SwiftAgentKit

enum ContextCompactionSummaryMessageAssembler: Sendable {
    static let referenceOnlyPrefix = """
[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Your current task is identified in the '## Active Task' section of the summary — resume exactly from there. Respond ONLY to the latest user message that appears AFTER this summary.

"""

    struct AssembledSummary: Sendable {
        let messages: [Message]
        let mergedIntoTail: Bool
        let mergedTail: [Message]?
        /// Standalone summary for checkpoint persistence when layout merges into the tail.
        let persistenceSummary: Message?
    }

    static func assemble(
        summaryBody: String,
        tail: [Message]
    ) -> AssembledSummary {
        let trimmed = summaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AssembledSummary(
                messages: [],
                mergedIntoTail: false,
                mergedTail: nil,
                persistenceSummary: nil
            )
        }
        let framed = referenceOnlyPrefix + trimmed
        if tail.isEmpty {
            let message = standaloneSummaryMessage(role: .user, content: framed)
            return AssembledSummary(
                messages: [message],
                mergedIntoTail: false,
                mergedTail: nil,
                persistenceSummary: message
            )
        }
        if tail.first?.role == .user {
            let message = standaloneSummaryMessage(role: .assistant, content: framed)
            return AssembledSummary(
                messages: [message],
                mergedIntoTail: false,
                mergedTail: nil,
                persistenceSummary: message
            )
        }
        if tail.first?.role == .assistant {
            var merged = tail
            let first = merged[0]
            merged[0] = Message(
                id: first.id,
                role: first.role,
                content: framed + "\n\n" + first.content,
                timestamp: first.timestamp,
                toolCalls: first.toolCalls,
                toolCallId: first.toolCallId
            )
            let persistenceSummary = standaloneSummaryMessage(role: .assistant, content: framed)
            return AssembledSummary(
                messages: [],
                mergedIntoTail: true,
                mergedTail: merged,
                persistenceSummary: persistenceSummary
            )
        }
        let message = standaloneSummaryMessage(role: .user, content: framed)
        return AssembledSummary(
            messages: [message],
            mergedIntoTail: false,
            mergedTail: nil,
            persistenceSummary: message
        )
    }

    private static func standaloneSummaryMessage(role: MessageRole, content: String) -> Message {
        Message(
            id: UUID(),
            role: role,
            content: content,
            timestamp: Date(),
            toolCalls: []
        )
    }
}
