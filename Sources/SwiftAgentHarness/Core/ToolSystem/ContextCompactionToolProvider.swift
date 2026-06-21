//
//  Local tool: compact_conversation — model-callable manual compaction trigger.
//  Gated by `manualToolMinUtilization` so a fresh conversation
//  cannot be force-compacted; never mutates the configuration's stored
//  `compactionCustomInstructionsBlock` (the optional `reason` is plumbed as a
//  one-shot override on the `ContextTransformInput`).
//

import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

/// Injected compaction seam so the tool provider stays isolated and easy to stub in tests.
protocol ContextCompactionPerforming: Sendable {
    func performManualCompaction(
        conversationID: UUID,
        trigger: ContextCompactionManualTrigger,
        reason: String?
    ) async throws -> ContextCompactionManualResult
}

/// `compact_conversation` model-callable tool. The model invokes this when it knows
/// the conversation has accumulated enough context that summarization is worthwhile.
struct ContextCompactionToolProvider: ToolProvider, ToolDescriptorHinting {

    static let compactConversationToolName = "compact_conversation"

    private let performer: any ContextCompactionPerforming
    private let logger: Logger?

    var name: String { "ContextCompaction" }
    var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.compactConversationToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
        ]
    }

    init(performer: any ContextCompactionPerforming, logger: Logger? = nil) {
        self.performer = performer
        self.logger = logger ?? SwiftAgentKitLogging.logger(
            for: .custom(subsystem: "SwiftAgentHarness", component: "ContextCompactionToolProvider")
        )
    }

    func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.compactConversationToolName,
                description:
                    "Compact (summarize) earlier messages in a conversation to reclaim context window. Use when switching tasks or when the thread has grown long enough that older detail no longer matters. The call is REFUSED for fresh conversations (those still well below the proactive compaction threshold) so the model cannot waste a turn compacting a short thread.",
                parameters: [
                    .init(name: "conversation_id", description: "Conversation UUID to compact.", type: "string", required: true),
                    .init(
                        name: "reason",
                        description: "Optional free-form note describing why compaction is being triggered (e.g. \"switching to debugging the auth flow\"). When provided, this is appended to the compaction prompt for this run only and is not persisted.",
                        type: "string",
                        required: false
                    ),
                ],
                type: .function
            )
        ]
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        guard toolCall.name == Self.compactConversationToolName else {
            throw Error.unknownTool(toolCall.name)
        }
        guard let conversationIdString = extractString(from: toolCall.arguments, key: "conversation_id") else {
            throw Error.missingParameter("conversation_id")
        }
        guard let conversationId = UUID(uuidString: conversationIdString) else {
            return toolError(toolCall, "Invalid conversation_id")
        }
        let reason = extractString(from: toolCall.arguments, key: "reason")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = (reason?.isEmpty == false) ? reason : nil

        let result: ContextCompactionManualResult
        do {
            result = try await performer.performManualCompaction(
                conversationID: conversationId,
                trigger: .modelTool,
                reason: normalizedReason
            )
        } catch let error where APILayerConversationRouteError.representsConversationNotFound(error) {
            return toolError(toolCall, "Conversation not found: \(conversationIdString)")
        } catch {
            logger?.warning("[ContextCompactionToolProvider] compact_conversation failed: \(String(describing: error))")
            return toolError(toolCall, "Compaction failed: \(error.localizedDescription)")
        }

        if let refusal = result.refusalReason {
            // 50%-of-threshold gate refusal — return a non-success ToolResult so the model
            // sees a clear refusal message.
            return ToolResult(
                success: false,
                content: refusal,
                metadata: .object([
                    "source": .string("context_compaction_tool"),
                    "action": .string("compact_conversation"),
                    "refused": .boolean(true),
                    "promptTokens": .integer(result.promptTokens),
                    "thresholdTokens": .integer(result.thresholdTokens),
                    "conversationId": .string(conversationIdString),
                ]),
                toolCallId: toolCall.id,
                error: refusal
            )
        }

        if let noop = result.noopReason {
            return ToolResult(
                success: false,
                content: "",
                metadata: .object([
                    "source": .string("context_compaction_tool"),
                    "action": .string("compact_conversation"),
                    "persisted": .boolean(false),
                    "noopReason": .string(noop),
                    "promptTokens": .integer(result.promptTokens),
                    "thresholdTokens": .integer(result.thresholdTokens),
                    "conversationId": .string(conversationIdString),
                ]),
                toolCallId: toolCall.id,
                error: "Compaction not run: \(noop)"
            )
        }

        let originalCount = result.originalMessages.count
        let compactedCount = result.compactedMessages?.count ?? originalCount
        let summary = "Compacted conversation \(conversationIdString): \(originalCount) → \(compactedCount) messages."
        var metadata: [String: JSON] = [
            "source": .string("context_compaction_tool"),
            "action": .string("compact_conversation"),
            "persisted": .boolean(result.persisted),
            "originalMessageCount": .integer(originalCount),
            "compactedMessageCount": .integer(compactedCount),
            "promptTokens": .integer(result.promptTokens),
            "thresholdTokens": .integer(result.thresholdTokens),
            "conversationId": .string(conversationIdString),
        ]
        if let diagnostics = result.diagnostics {
            metadata["diagnostics"] = .string(diagnostics)
        }

        return ToolResult(
            success: true,
            content: summary,
            metadata: .object(metadata),
            toolCallId: toolCall.id
        )
    }

    private func toolError(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(
            success: false,
            content: "",
            metadata: .object(["source": .string("context_compaction_tool")]),
            toolCallId: toolCall.id,
            error: message
        )
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments,
              let value = dict[key]
        else {
            return nil
        }
        if case .string(let s) = value { return s }
        return nil
    }
}

extension ContextCompactionToolProvider {
    enum Error: Swift.Error, Sendable {
        case unknownTool(String)
        case missingParameter(String)
    }
}
