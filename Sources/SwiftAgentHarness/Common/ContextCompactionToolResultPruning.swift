import Foundation
import SwiftAgentKit

/// Replacement-content strategy used when a tool result is dropped during pre-compaction hygiene.
///
/// - `blankMarker`: rung 1 — replace with the content-free `clearedToolResultContentPlaceholder`.
/// - `oneLineSummary`: rung 2 — replace with a deterministic 1-line summary built from the call's
///   intent and the result-only signal (see `DeterministicToolResultSummary`).
public enum ToolResultPruneReplacementMode: String, Sendable, Equatable {
    case blankMarker
    case oneLineSummary
}

/// Strips volatile tool result text for the **compaction** summarizer LLM only; persisted conversation messages are unchanged.
public enum ContextCompactionToolResultPruning: Sendable {
    public static let clearedToolResultContentPlaceholder = "[Old tool result content cleared]"

    /// Two independent passes operating on disjoint sets of resolvable `role == .tool` messages
    /// in `messages` (the compaction **middle**), where each tool message resolves its tool name
    /// via `toolCallId` against assistant `toolCalls` from `toolCallNameResolutionContext` + `messages`:
    ///
    /// 1. **Per-listed-name cap**: for each `name` ∈ `toolNamesToPrune`, keep the last
    ///    `maxRecentPerListedName` resolvable tool messages whose name equals `name`; clear earlier
    ///    ones with the placeholder. Buckets are independent (e.g. last 5 `web-fetch` AND last 5
    ///    `web-search`).
    /// 2. **Unlisted recency cap**: among resolvable tool messages whose name is **not** in
    ///    `toolNamesToPrune`, keep the last `maxRecentUnlistedToolResults`; clear earlier ones.
    ///
    /// Tool results whose `toolCallId` does not map to any assistant in `toolCallNameResolutionContext` +
    /// `messages` are left unchanged (never cleared by either pass) so we do not drop unattributed
    /// content.
    public static func applyingToolResultContentPruningForCompactionLLM(
        messages: [Message],
        toolNamesToPrune: Set<String>,
        maxRecentPerListedName: Int = 5,
        maxRecentUnlistedToolResults: Int = 5,
        toolCallNameResolutionContext: [Message] = [],
        replacementMode: ToolResultPruneReplacementMode = .blankMarker,
        toolNamesProtectedFromPruning: Set<String> = []
    ) -> [Message] {
        let toolCallIdToCall = buildToolCallIdToCall(
            resolutionContext: toolCallNameResolutionContext,
            middle: messages
        )
        let afterListed = applyPerListedNameRecencyCap(
            messages: messages,
            toolNamesToPrune: toolNamesToPrune,
            maxKeep: max(0, maxRecentPerListedName),
            toolCallIdToCall: toolCallIdToCall,
            replacementMode: replacementMode,
            toolNamesProtectedFromPruning: toolNamesProtectedFromPruning
        )
        return applyUnlistedRecencyCap(
            messages: afterListed,
            toolNamesToPrune: toolNamesToPrune,
            maxKeep: max(0, maxRecentUnlistedToolResults),
            toolCallIdToCall: toolCallIdToCall,
            replacementMode: replacementMode,
            toolNamesProtectedFromPruning: toolNamesProtectedFromPruning
        )
    }

    // MARK: - Private

    /// Merges `toolCalls` from the optional **head** (or other prefix) with `middle` so tool results in the middle still resolve when the calling assistant is outside the middle slice. Carries the full `ToolCall` (arguments included) so rung-2 summaries can reconstruct intent.
    private static func buildToolCallIdToCall(
        resolutionContext: [Message],
        middle: [Message]
    ) -> [String: ToolCall] {
        var map: [String: ToolCall] = [:]
        for m in resolutionContext + middle where m.role == .assistant {
            for tc in m.toolCalls {
                if let id = tc.id { map[id] = tc }
            }
        }
        return map
    }

    /// For each tool name in `toolNamesToPrune`, group the resolvable tool messages whose name
    /// matches and keep the last `maxKeep` per group. Earlier results in each per-name bucket are
    /// cleared with the placeholder. Tool messages whose name is not in `toolNamesToPrune` are
    /// untouched here.
    private static func applyPerListedNameRecencyCap(
        messages: [Message],
        toolNamesToPrune: Set<String>,
        maxKeep: Int,
        toolCallIdToCall: [String: ToolCall],
        replacementMode: ToolResultPruneReplacementMode,
        toolNamesProtectedFromPruning: Set<String>
    ) -> [Message] {
        guard !toolNamesToPrune.isEmpty else { return messages }
        var indicesByName: [String: [Int]] = [:]
        for (i, m) in messages.enumerated() where m.role == .tool {
            guard m.content != Self.clearedToolResultContentPlaceholder,
                  let tid = m.toolCallId, !tid.isEmpty,
                  let name = toolCallIdToCall[tid]?.name,
                  toolNamesToPrune.contains(name),
                  !isProtectedFromPruning(toolName: name, configuredProtectedNames: toolNamesProtectedFromPruning)
            else { continue }
            indicesByName[name, default: []].append(i)
        }
        var indicesToClear: Set<Int> = []
        for (_, indices) in indicesByName where indices.count > maxKeep {
            for idx in indices.dropLast(maxKeep) {
                indicesToClear.insert(idx)
            }
        }
        guard !indicesToClear.isEmpty else { return messages }
        var out = Array(messages)
        for idx in indicesToClear {
            let resolvedCall = out[idx].toolCallId.flatMap { toolCallIdToCall[$0] }
            out[idx] = makeReplacedToolMessage(from: out[idx], toolCall: resolvedCall, mode: replacementMode)
        }
        return out
    }

    /// Recency cap for resolvable tool messages whose name is **not** in `toolNamesToPrune`.
    private static func applyUnlistedRecencyCap(
        messages: [Message],
        toolNamesToPrune: Set<String>,
        maxKeep: Int,
        toolCallIdToCall: [String: ToolCall],
        replacementMode: ToolResultPruneReplacementMode,
        toolNamesProtectedFromPruning: Set<String>
    ) -> [Message] {
        let placeholder = Self.clearedToolResultContentPlaceholder
        var indices: [Int] = []
        for (i, m) in messages.enumerated() where m.role == .tool {
            guard m.content != placeholder,
                  let tid = m.toolCallId, !tid.isEmpty,
                  let name = toolCallIdToCall[tid]?.name,
                  !toolNamesToPrune.contains(name),
                  !isProtectedFromPruning(toolName: name, configuredProtectedNames: toolNamesProtectedFromPruning)
            else { continue }
            indices.append(i)
        }
        if indices.count <= maxKeep { return messages }
        var out = Array(messages)
        for idx in indices.dropLast(maxKeep) {
            let resolvedCall = out[idx].toolCallId.flatMap { toolCallIdToCall[$0] }
            out[idx] = makeReplacedToolMessage(from: out[idx], toolCall: resolvedCall, mode: replacementMode)
        }
        return out
    }

    /// Rebuilds a `tool` message whose payload is being shed, substituting content per `mode`.
    /// `.oneLineSummary` requires the resolved `ToolCall` to reconstruct intent; if it is missing
    /// (defensive only — unresolvable ids are never selected for replacement) it falls back to the
    /// blank marker so we never emit a summary with missing intent.
    private static func makeReplacedToolMessage(
        from m: Message,
        toolCall: ToolCall?,
        mode: ToolResultPruneReplacementMode
    ) -> Message {
        let content: String
        switch mode {
        case .blankMarker:
            content = Self.clearedToolResultContentPlaceholder
        case .oneLineSummary:
            if let toolCall {
                content = DeterministicToolResultSummary.line(
                    for: toolCall,
                    result: ToolResult(
                        success: true,
                        content: m.content,
                        metadata: .object([:]),
                        toolCallId: m.toolCallId
                    )
                )
            } else {
                content = Self.clearedToolResultContentPlaceholder
            }
        }
        return Message(
            id: m.id,
            role: m.role,
            content: content,
            timestamp: m.timestamp,
            images: m.images,
            toolCalls: m.toolCalls,
            toolCallId: m.toolCallId,
            responseFormat: m.responseFormat
        )
    }

    private static func isProtectedFromPruning(
        toolName: String,
        configuredProtectedNames: Set<String>
    ) -> Bool {
        ToolRegistryResultFormattingPolicy.isCompactionProtectedForPruning(
            toolName: toolName,
            configuredProtectedNames: configuredProtectedNames
        )
    }
}
