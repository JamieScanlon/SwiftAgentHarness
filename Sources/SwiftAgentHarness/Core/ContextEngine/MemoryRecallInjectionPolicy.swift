import Foundation
import SwiftAgentKit

/// Tier 2 memory-recall injection policy (spec: memory-injection.md § Budgeting).
enum MemoryRecallInjectionPolicy {
    static let maxHitCount = 5
    static let perFileByteCap = 4_096
    static let totalByteCap = 16_384
    static let truncationMarker = "\n[...memory recall truncated...]"

    /// Applies per-file and total byte caps; preserves relevance order (index 0 = highest).
    static func budgetedHits(_ hits: [MemoryRecallHit]) -> [MemoryRecallHit] {
        let capped = Array(hits.prefix(maxHitCount))
        var out: [MemoryRecallHit] = []
        var totalBytes = 0
        for hit in capped {
            let truncated = truncateToByteBudget(hit.formattedBody, maxBytes: perFileByteCap)
            let bodyBytes = Data(truncated.utf8).count
            if totalBytes + bodyBytes > totalByteCap {
                break
            }
            totalBytes += bodyBytes
            out.append(MemoryRecallHit(selectionKey: hit.selectionKey, formattedBody: truncated))
        }
        return out
    }

    /// Sheds lowest-relevance hits until recall fits without firing the proactive compaction trigger.
    static func hitsFittingCompactionGuard(
        hits: [MemoryRecallHit],
        baseMessages: [Message],
        recallEntryID: UUID,
        modelLimit: Int,
        lastPromptTokens: Int?,
        config: ContextCompactionConfiguration
    ) -> [MemoryRecallHit] {
        var candidate = budgetedHits(hits)
        while !candidate.isEmpty {
            guard let recallMessage = makeRecallMessage(hits: candidate, entryID: recallEntryID) else {
                return []
            }
            if fitsWithoutCompactionTrigger(
                baseMessages: baseMessages,
                recallMessage: recallMessage,
                modelLimit: modelLimit,
                lastPromptTokens: lastPromptTokens,
                config: config
            ) {
                return candidate
            }
            candidate.removeLast()
        }
        return []
    }

    static func fitsWithoutCompactionTrigger(
        baseMessages: [Message],
        recallMessage: Message?,
        modelLimit: Int,
        lastPromptTokens: Int?,
        config: ContextCompactionConfiguration
    ) -> Bool {
        var messages = baseMessages
        if let recallMessage {
            messages = insertLateRecall(recallMessage, into: messages)
        }
        return !ContextCompactionPolicy.proactiveTriggerFires(
            messages: messages,
            modelContextLimitTokens: modelLimit,
            lastActualPromptTokens: lastPromptTokens,
            config: config
        )
    }

    static func makeRecallMessage(hits: [MemoryRecallHit], entryID: UUID) -> Message? {
        let bodies = hits.map(\.formattedBody).filter { !$0.isEmpty }
        guard !bodies.isEmpty else { return nil }
        let fenced = MemoryContextFencer.fence(bodies.joined(separator: "\n\n"))
        return HarnessInjectedMessageMetadata.systemMessage(
            id: entryID,
            content: """
\(HarnessInjectedMessagePrefixes.memoryRecall)
\(fenced)
"""
        )
    }

    /// Inserts recall immediately before the last user message (junior to conversation tail).
    static func insertLateRecall(_ recall: Message, into messages: [Message]) -> [Message] {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return messages + [recall]
        }
        var out = messages
        out.insert(recall, at: lastUserIndex)
        return out
    }

    private static func truncateToByteBudget(_ content: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var data = Data(content.utf8)
        guard data.count > maxBytes else { return content }
        let markerData = Data(truncationMarker.utf8)
        let budget = max(0, maxBytes - markerData.count)
        let prefix = data.prefix(budget)
        if let lastNewline = prefix.lastIndex(of: 0x0A) {
            data = Data(prefix[..<lastNewline])
        } else {
            data = prefix
        }
        return String(decoding: data, as: UTF8.self) + truncationMarker
    }
}
