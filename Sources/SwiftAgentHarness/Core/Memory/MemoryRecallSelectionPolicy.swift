import Foundation
import SwiftAgentKit

/// Tier-2 recall selector post-processing (spec: memory-injection.md § bias toward nothing).
enum MemoryRecallSelectionPolicy {
    private static let gotchaSignals = [
        "gotcha",
        "known issue",
        "pitfall",
        "caveat",
        "quirk",
        "workaround",
        "limitation",
        "bug",
        "broken",
        "watch out",
    ]

    static func activeToolNames(from messages: [Message]) -> Set<String> {
        Set(
            messages
                .flatMap(\.toolCalls)
                .map(\.name)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func applyPostSelectionFilters(
        selectionKeys: [String],
        manifest: [MemoryManifestEntry],
        activeToolNames: Set<String>
    ) -> [String] {
        filterUsageReferenceRedundancy(
            selectionKeys: Array(selectionKeys.prefix(5)),
            manifest: manifest,
            activeToolNames: activeToolNames
        )
    }

    static func filterUsageReferenceRedundancy(
        selectionKeys: [String],
        manifest: [MemoryManifestEntry],
        activeToolNames: Set<String>
    ) -> [String] {
        guard !activeToolNames.isEmpty else { return selectionKeys }
        let byKey = Dictionary(uniqueKeysWithValues: manifest.map { ($0.selectionKey, $0) })
        return selectionKeys.filter { key in
            guard let entry = byKey[key] else { return true }
            return !shouldDropUsageReference(entry: entry, activeToolNames: activeToolNames)
        }
    }

    static func isGotchaReference(_ entry: MemoryManifestEntry) -> Bool {
        let header = "\(entry.name) \(entry.description)".lowercased()
        return gotchaSignals.contains { header.contains($0) }
    }

    static func shouldDropUsageReference(entry: MemoryManifestEntry, activeToolNames: Set<String>) -> Bool {
        guard entry.memoryType == .reference else { return false }
        guard !isGotchaReference(entry) else { return false }
        return mentionsActiveTool(entry: entry, activeToolNames: activeToolNames)
    }

    private static func mentionsActiveTool(entry: MemoryManifestEntry, activeToolNames: Set<String>) -> Bool {
        let headerText = "\(entry.name) \(entry.description) \(entry.filename)".lowercased()
        let headerTokens = tokenSet(headerText)
        for toolName in activeToolNames {
            let toolTokens = tokenSet(toolName)
            if toolTokens.isEmpty { continue }
            if toolTokens.isSubset(of: headerTokens) { return true }
            let normalized = toolName.lowercased().replacingOccurrences(of: "_", with: " ")
            if headerText.contains(normalized) { return true }
        }
        return false
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}
