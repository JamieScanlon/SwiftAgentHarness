import Foundation
import Logging
import SwiftAgentKit

/// Provider-agnostic guard that guarantees a message array is renderable by a standard chat
/// template before it is dispatched to an LLM.
///
/// Standard chat templates (e.g. qwen3's jinja) walk messages in order and cannot render a
/// history that begins with a dangling tool result or has no system/user framing. This type
/// enforces the structural invariants the harness relies on:
/// - the array never begins with a `.tool` message;
/// - every `.tool` message is preceded by an `.assistant` message carrying the matching
///   `tool_call_id` (orphans are dropped);
/// - at least one `.system` message is present (the base harness prompt is injected if missing).
enum RenderableMessageInvariant: Sendable {
    /// Drops orphaned tool results: any `.tool` message whose `toolCallId` has no matching
    /// `assistant` `tool_calls` id earlier in the array (which also removes leading tool results
    /// whose originating assistant turn was trimmed away).
    static func repairToolPairs(_ messages: [Message]) -> [Message] {
        var result: [Message] = []
        result.reserveCapacity(messages.count)
        var seenToolCallIDs: Set<String> = []
        for message in messages {
            switch message.role {
            case .assistant:
                for call in message.toolCalls {
                    if let id = call.id {
                        seenToolCallIDs.insert(id)
                    }
                }
                result.append(message)
            case .tool:
                guard let toolCallId = message.toolCallId, seenToolCallIDs.contains(toolCallId) else {
                    continue
                }
                result.append(message)
            default:
                result.append(message)
            }
        }
        return result
    }

    /// Guarantees at least one `.system` message exists. When none is present, a harness-injected
    /// system message with empty content is prepended as a last resort. CE assemble is responsible
    /// for canonical system prompt expansion; adapter expansion remains a legacy fallback when the
    /// assembled prompt digest is absent from dispatch metadata.
    static func ensuringSystemPrompt(_ messages: [Message]) -> [Message] {
        guard !messages.contains(where: { $0.role == .system }) else { return messages }
        let injected = HarnessInjectedMessageMetadata.systemMessage(id: UUID(), content: "")
        return [injected] + messages
    }

    /// Final pre-dispatch sanitization: repairs tool pairing then guarantees a system message.
    /// Logs a `warning` whenever it has to drop, repair, or inject so the condition is observable.
    static func sanitizeForDispatch(_ messages: [Message], logger: Logger?) -> [Message] {
        let repaired = repairToolPairs(messages)
        if repaired.count != messages.count {
            logger?.warning(
                "[RenderableMessageInvariant] dropped \(messages.count - repaired.count) orphaned tool result(s) before dispatch"
            )
        }
        let withSystem = ensuringSystemPrompt(repaired)
        if withSystem.count != repaired.count {
            logger?.warning(
                "[RenderableMessageInvariant] injected harness system prompt; assembled array had no system message"
            )
        }
        return withSystem
    }
}
