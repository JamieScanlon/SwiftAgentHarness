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
/// - at least one `.system` message is present (the base harness prompt is injected if missing);
/// - at least one renderable `.user` query is present (non-empty, not a `<tool_response>` wrapper).
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

    /// True when trimmed content looks like a provider-style tool-response wrapper rather than a
    /// genuine user query (defensive; harness normally uses `role: .tool`).
    static func isToolResponseWrapper(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<tool_response>")
    }

    /// A renderable user query: `.user` role, non-empty content, not a `<tool_response>` wrapper.
    static func isRenderableUserQuery(_ message: Message) -> Bool {
        guard message.role == .user else { return false }
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !isToolResponseWrapper(trimmed)
    }

    /// Guarantees at least one renderable user query. When absent, promotes a merged compaction
    /// summary when possible; otherwise injects a harness-injected continuation user message.
    static func ensuringRenderableUserQuery(_ messages: [Message]) -> [Message] {
        if messages.contains(where: isRenderableUserQuery) {
            return messages
        }
        if let promoted = promoteMergedCompactionSummary(messages) {
            return promoted
        }
        return injectLastResortUserQuery(messages)
    }

    /// Final pre-dispatch sanitization: repairs tool pairing, guarantees a system message, then
    /// guarantees a renderable user query. Logs a `warning` whenever it has to drop, repair, or
    /// inject so the condition is observable.
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
        let withUser = ensuringRenderableUserQuery(withSystem)
        if !withSystem.contains(where: isRenderableUserQuery) {
            logger?.warning(
                "[RenderableMessageInvariant] repaired missing renderable user query before dispatch"
            )
        }
        return withUser
    }

    // MARK: - Private

    private static let continueSentinel = "Continue from the current context."

    private static func promoteMergedCompactionSummary(_ messages: [Message]) -> [Message]? {
        let prefix = ContextCompactionSummaryMessageAssembler.referenceOnlyPrefix
        guard let index = messages.firstIndex(where: { $0.content.hasPrefix(prefix) }) else {
            return nil
        }
        let host = messages[index]
        let framedContent = host.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !framedContent.isEmpty else { return nil }

        let userMessage = Message(
            id: UUID(),
            role: .user,
            content: framedContent,
            timestamp: host.timestamp,
            toolCalls: [],
            inputTrustRaw: HarnessInjectedMessageMetadata.inputTrustRaw
        )
        var result = messages
        // Summary-only assistant (no tool metadata): convert in place to a user turn.
        // Assistant/tool-bearing hosts keep their role; insert the promoted user query before them.
        if host.role == .assistant, host.toolCalls.isEmpty, host.toolCallId == nil {
            result[index] = userMessage
        } else {
            result.insert(userMessage, at: index)
        }
        return result
    }

    private static func injectLastResortUserQuery(_ messages: [Message]) -> [Message] {
        let content = activeTaskContent(from: messages) ?? continueSentinel
        let injected = Message(
            id: UUID(),
            role: .user,
            content: content,
            timestamp: Date(),
            toolCalls: [],
            inputTrustRaw: HarnessInjectedMessageMetadata.inputTrustRaw
        )
        if let lastSystem = messages.lastIndex(where: { $0.role == .system }) {
            var result = messages
            result.insert(injected, at: lastSystem + 1)
            return result
        }
        return [injected] + messages
    }

    private static func activeTaskContent(from messages: [Message]) -> String? {
        let marker = "## Active Task"
        for message in messages {
            guard let range = message.content.range(of: marker) else { continue }
            let afterMarker = message.content[range.upperBound...]
            var body: [String] = []
            var started = false
            for line in afterMarker.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !started {
                    if trimmed.isEmpty { continue }
                    if trimmed.hasPrefix("## ") { break }
                    started = true
                    body.append(trimmed)
                    continue
                }
                if trimmed.hasPrefix("## ") { break }
                body.append(trimmed)
            }
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return joined
            }
        }
        return nil
    }
}
