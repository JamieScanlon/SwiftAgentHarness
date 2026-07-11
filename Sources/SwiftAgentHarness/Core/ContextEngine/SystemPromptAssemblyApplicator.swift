import Foundation
import SwiftAgentKit

/// Embeds CE-assembled system prompt text into the canonical non-harness system message slot.
enum SystemPromptAssemblyApplicator: Sendable {
    static func userSystemPrompt(from messages: [Message]) -> String? {
        guard let index = SystemPromptDispatchCodec.canonicalSystemMessageIndex(in: messages) else {
            return nil
        }
        return messages[index].content
    }

    static func apply(assembledText: String, to messages: [Message]) -> [Message] {
        guard !assembledText.isEmpty else { return messages }
        guard let index = SystemPromptDispatchCodec.canonicalSystemMessageIndex(in: messages) else {
            var result = messages
            let system = Message(
                id: UUID(),
                role: .system,
                content: assembledText,
                timestamp: Date(),
                toolCalls: []
            )
            result.insert(system, at: 0)
            return result
        }
        var result = messages
        let existing = messages[index]
        result[index] = Message(
            id: existing.id,
            role: .system,
            content: assembledText,
            timestamp: existing.timestamp,
            toolCalls: existing.toolCalls,
            inputTrustRaw: existing.inputTrustRaw
        )
        return result
    }
}
