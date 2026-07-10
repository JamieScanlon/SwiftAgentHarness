import Foundation
import SwiftAgentKit

/// Content prefixes for harness-injected system messages (legacy coverage filter + injection sites).
enum HarnessInjectedMessagePrefixes {
    static let memoryContext = "[Memory Context]"
    static let memoryRecall = "[Memory Recall]"
    static let activeMemoryRecall = "[Active Memory Recall]"
    static let triggerProvenance = "[trigger-context]"

    static let coveragePrefixes: [String] = [
        memoryContext,
        memoryRecall,
        activeMemoryRecall,
        triggerProvenance,
    ]
}

/// Structural marker for harness-injected messages until SwiftAgentKit exposes a dedicated field.
enum HarnessInjectedMessageMetadata {
    static let inputTrustRaw = "harness_injected"

    static func isHarnessInjected(_ message: Message) -> Bool {
        if MessageInputTrustCodec.sanitizedInputTrustRaw(message.inputTrustRaw) == inputTrustRaw {
            return true
        }
        guard message.role == .system else { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return HarnessInjectedMessagePrefixes.coveragePrefixes.contains { trimmed.hasPrefix($0) }
    }

    static func systemMessage(id: UUID, content: String, timestamp: Date = Date()) -> Message {
        Message(
            id: id,
            role: .system,
            content: content,
            timestamp: timestamp,
            toolCalls: [],
            inputTrustRaw: inputTrustRaw
        )
    }

    static func assistantMessage(id: UUID, content: String, timestamp: Date = Date()) -> Message {
        Message(
            id: id,
            role: .assistant,
            content: content,
            timestamp: timestamp,
            toolCalls: [],
            inputTrustRaw: inputTrustRaw
        )
    }
}
