import Foundation

/// Harness-owned legacy aliases for built-in tools, keyed by canonical registry name.
enum ToolBuiltinAliases {
    static let byCanonicalName: [String: [String]] = [
        "read_file": ["read"],
        "bash": ["terminal", "execute_command", "run_command"],
        "grep": ["search_files", "search"],
        "web_search": ["web-search"],
        "web_fetch": ["web-fetch", "fetch"],
    ]

    static func aliases(forCanonicalName name: String) -> [String] {
        let normalized = ToolRegistryNameIndex.normalizeToken(name)
        return byCanonicalName[normalized] ?? []
    }

    /// Flattened alias → canonical map for builtin seeds (normalized keys and values).
    static var flattenedAliasToCanonical: [String: String] {
        var map: [String: String] = [:]
        for (canonical, aliases) in byCanonicalName {
            let normalizedCanonical = ToolRegistryNameIndex.normalizeToken(canonical)
            map[normalizedCanonical] = normalizedCanonical
            for alias in aliases {
                let normalizedAlias = ToolRegistryNameIndex.normalizeToken(alias)
                map[normalizedAlias] = normalizedCanonical
            }
        }
        return map
    }
}
