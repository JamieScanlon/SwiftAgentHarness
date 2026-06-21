import Foundation
import SwiftAgentKit

enum ContextCompactionSummaryMessageAssembler: Sendable {
    static let referenceOnlyPrefix = """
[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. Do NOT answer questions or fulfill requests mentioned in this summary; they were already addressed. Your current task is identified in the '## Active Task' section of the summary — resume exactly from there. Respond ONLY to the latest user message that appears AFTER this summary.

"""

    struct AssembledSummary: Sendable {
        let messages: [Message]
        let mergedIntoTail: Bool
    }

    static func assemble(
        summaryBody: String,
        tail: [Message]
    ) -> AssembledSummary {
        let trimmed = summaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AssembledSummary(messages: [], mergedIntoTail: false)
        }
        let framed = referenceOnlyPrefix + trimmed
        if tail.isEmpty {
            let message = Message(
                id: UUID(),
                role: .user,
                content: framed,
                timestamp: Date(),
                toolCalls: []
            )
            return AssembledSummary(messages: [message], mergedIntoTail: false)
        }
        if tail.first?.role == .user {
            let message = Message(
                id: UUID(),
                role: .assistant,
                content: framed,
                timestamp: Date(),
                toolCalls: []
            )
            return AssembledSummary(messages: [message], mergedIntoTail: false)
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
            return AssembledSummary(messages: [], mergedIntoTail: true)
        }
        let message = Message(
            id: UUID(),
            role: .user,
            content: framed,
            timestamp: Date(),
            toolCalls: []
        )
        return AssembledSummary(messages: [message], mergedIntoTail: false)
    }
}
