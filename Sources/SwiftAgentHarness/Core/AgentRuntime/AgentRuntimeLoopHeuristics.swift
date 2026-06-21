import Foundation
import SwiftAgentKit

enum AgentRuntimeLoopHeuristics {
    /// Messages from the user message that started this stream (inclusive).
    static func messagesForHeuristics(_ messages: [Message], anchorUserMessageID: UUID?) -> [Message] {
        guard let anchor = anchorUserMessageID,
              let idx = messages.firstIndex(where: { $0.id == anchor && $0.role == .user })
        else {
            return messages
        }
        return Array(messages[idx...])
    }

    /// True only when the last three messages are empty assistant messages with no tools/images.
    static func hasRunawayEmptyAssistantStreak(_ messages: [Message]) -> Bool {
        guard messages.count >= 3 else { return false }
        let lastThree = messages.suffix(3)
        return lastThree.allSatisfy { isEmptyAssistantWithNoToolCalls($0) }
    }

    static func consecutiveChattyAssistantCount(atEndOf messages: [Message]) -> Int {
        let minChars = 40
        var n = 0
        for message in messages.reversed() {
            guard message.role == .assistant else { break }
            if !message.toolCalls.isEmpty { break }
            if !message.images.isEmpty { break }
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < minChars { break }
            n += 1
        }
        return n
    }

    static func maxRepeatToolCallStreak(in messages: [Message], threshold: Int) -> Bool {
        guard threshold >= 2 else { return false }
        var run = 0
        var lastFingerprint: String?
        for message in messages where message.role == .assistant {
            guard let fp = toolCallFingerprint(for: message) else {
                lastFingerprint = nil
                run = 0
                continue
            }
            if fp == lastFingerprint {
                run += 1
            } else {
                lastFingerprint = fp
                run = 1
            }
            if run >= threshold {
                return true
            }
        }
        return false
    }

    private static func isEmptyAssistantWithNoToolCalls(_ message: Message) -> Bool {
        guard message.role == .assistant else { return false }
        if !message.toolCalls.isEmpty { return false }
        if !message.images.isEmpty { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    private static func toolCallFingerprint(for message: Message) -> String? {
        guard message.role == .assistant, !message.toolCalls.isEmpty else { return nil }
        let parts = message.toolCalls.map { "\($0.name):\($0.arguments)" }.sorted()
        return parts.joined(separator: "|")
    }
}
