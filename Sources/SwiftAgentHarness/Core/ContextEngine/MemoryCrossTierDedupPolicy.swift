import Foundation
import SwiftAgentKit

/// Cross-tier dedupe by memory file id (spec: memory-injection.md § Ordering).
enum MemoryCrossTierDedupPolicy {
    private static func bodyMarkerPattern() -> Regex<(Substring, Substring)> {
        /<!--\s*([^>]+?)\s*-->/
    }

    /// Selection keys for files whose full body is embedded in tier-1 text (`<!-- filename -->` markers).
    static func bodyProjectedSelectionKeys(fromTier1Content content: String?) -> Set<String> {
        guard let content, !content.isEmpty else { return [] }
        return selectionKeysFromFormattedBodies(content)
    }

    static func bodyProjectedSelectionKeys(fromTier2Hits hits: [MemoryRecallHit]) -> Set<String> {
        Set(hits.map(\.selectionKey).filter { !$0.isEmpty })
    }

    static func bodyProjectedSelectionKeys(fromRecallMessage message: Message) -> Set<String> {
        guard message.role == .system,
              HarnessInjectedMessageMetadata.isHarnessInjected(message),
              message.content.contains(HarnessInjectedMessagePrefixes.memoryRecall) else {
            return []
        }
        return selectionKeysFromFormattedBodies(message.content)
    }

    /// Drops hits whose `selectionKey` is already body-projected; preserves relevance order.
    static func filterTier2Hits(_ hits: [MemoryRecallHit], excluding alreadyProjected: Set<String>) -> [MemoryRecallHit] {
        guard !alreadyProjected.isEmpty else { return hits }
        return hits.filter { hit in
            let key = hit.selectionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return true }
            return !alreadyProjected.contains(key)
        }
    }

    static func exclusionPromptFragment(keys: Set<String>) -> String? {
        let sorted = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
        guard !sorted.isEmpty else { return nil }
        return """
        Files already fully injected in this turn's memory-recall block — do not read or summarize them again:
        \(sorted.joined(separator: ", "))
        """
    }

    private static func selectionKeysFromFormattedBodies(_ text: String) -> Set<String> {
        var keys: Set<String> = []
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            guard let match = line.firstMatch(of: bodyMarkerPattern()) else { continue }
            let filename = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !filename.isEmpty else { continue }
            if line.contains("[scope:user]") {
                keys.insert("user/\(filename)")
            } else {
                keys.insert(filename)
            }
        }
        return keys
    }
}
