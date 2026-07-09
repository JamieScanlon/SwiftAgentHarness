import Foundation

enum ToolRegistrySpillPolicy {
    private static let spillExemptCanonicalNames: Set<String> = [
        "read_file",
        "glob",
        "grep",
    ]

    static func isSpillExempt(toolName: String) -> Bool {
        let canonical = ToolRegistryNameIndex.normalizeToken(toolName)
        if spillExemptCanonicalNames.contains(canonical) {
            return true
        }
        for exempt in spillExemptCanonicalNames {
            if ToolBuiltinAliases.aliases(forCanonicalName: exempt).contains(canonical) {
                return true
            }
        }
        return false
    }

    static func effectiveMaxResultSizeBeforeSpill(
        entry: ToolRegistryEntry?,
        configuration: ToolResultFormattingConfiguration
    ) -> Int {
        if let entry, entry.spillExempt {
            return Int.max
        }
        if let entry, let override = entry.maxResultSizeBeforeSpill {
            return max(0, override)
        }
        return max(0, configuration.defaultMaxResultSizeBeforeSpill)
    }
}
