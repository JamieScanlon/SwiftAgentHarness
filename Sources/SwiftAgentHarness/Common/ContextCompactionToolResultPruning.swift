import Foundation
import SwiftAgentKit

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
        toolCallNameResolutionContext: [Message] = []
    ) -> [Message] {
        let toolCallIdToName = buildToolCallIdToName(
            resolutionContext: toolCallNameResolutionContext,
            middle: messages
        )
        let afterListed = applyPerListedNameRecencyCap(
            messages: messages,
            toolNamesToPrune: toolNamesToPrune,
            maxKeep: max(0, maxRecentPerListedName),
            toolCallIdToName: toolCallIdToName
        )
        return applyUnlistedRecencyCap(
            messages: afterListed,
            toolNamesToPrune: toolNamesToPrune,
            maxKeep: max(0, maxRecentUnlistedToolResults),
            toolCallIdToName: toolCallIdToName
        )
    }

    // MARK: - Private

    /// Merges `toolCalls` from the optional **head** (or other prefix) with `middle` so tool results in the middle still resolve when the calling assistant is outside the middle slice.
    private static func buildToolCallIdToName(
        resolutionContext: [Message],
        middle: [Message]
    ) -> [String: String] {
        var map: [String: String] = [:]
        for m in resolutionContext + middle where m.role == .assistant {
            for tc in m.toolCalls {
                if let id = tc.id { map[id] = tc.name }
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
        toolCallIdToName: [String: String]
    ) -> [Message] {
        guard !toolNamesToPrune.isEmpty else { return messages }
        var indicesByName: [String: [Int]] = [:]
        for (i, m) in messages.enumerated() where m.role == .tool {
            guard m.content != Self.clearedToolResultContentPlaceholder,
                  let tid = m.toolCallId, !tid.isEmpty,
                  let name = toolCallIdToName[tid],
                  toolNamesToPrune.contains(name)
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
            out[idx] = makeToolMessageWithClearedContent(from: out[idx])
        }
        return out
    }

    /// Recency cap for resolvable tool messages whose name is **not** in `toolNamesToPrune`.
    private static func applyUnlistedRecencyCap(
        messages: [Message],
        toolNamesToPrune: Set<String>,
        maxKeep: Int,
        toolCallIdToName: [String: String]
    ) -> [Message] {
        let placeholder = Self.clearedToolResultContentPlaceholder
        var indices: [Int] = []
        for (i, m) in messages.enumerated() where m.role == .tool {
            guard m.content != placeholder,
                  let tid = m.toolCallId, !tid.isEmpty,
                  let name = toolCallIdToName[tid],
                  !toolNamesToPrune.contains(name)
            else { continue }
            indices.append(i)
        }
        if indices.count <= maxKeep { return messages }
        var out = Array(messages)
        for idx in indices.dropLast(maxKeep) {
            out[idx] = makeToolMessageWithClearedContent(from: out[idx])
        }
        return out
    }

    private static func makeToolMessageWithClearedContent(from m: Message) -> Message {
        Message(
            id: m.id,
            role: m.role,
            content: Self.clearedToolResultContentPlaceholder,
            timestamp: m.timestamp,
            images: m.images,
            toolCalls: m.toolCalls,
            toolCallId: m.toolCallId,
            responseFormat: m.responseFormat
        )
    }
}
