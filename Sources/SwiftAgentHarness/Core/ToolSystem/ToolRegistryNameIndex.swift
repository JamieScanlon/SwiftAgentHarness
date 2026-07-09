import Foundation

/// Registry-backed legacy alias index for tool name normalization.
///
/// Built from catalog entries plus builtin alias seeds. One resolver for policy,
/// persisted grants, gateway matching, and dispatch.
struct ToolRegistryNameIndex: Sendable, Equatable {
    private let aliasToCanonical: [String: String]

    init(aliasToCanonical: [String: String]) {
        self.aliasToCanonical = aliasToCanonical
    }

    /// Builtin seeds only — used at config load before a catalog snapshot exists.
    static let builtIn: ToolRegistryNameIndex = build(entries: [])

    struct BuildDiagnostics: Sendable {
        var droppedAliases: [(alias: String, requestedCanonical: String, reason: String)]
    }

    struct BuildResult: Sendable {
        let index: ToolRegistryNameIndex
        let diagnostics: BuildDiagnostics
    }

    static func build(entries: [ToolRegistryEntry]) -> ToolRegistryNameIndex {
        buildWithDiagnostics(entries: entries).index
    }

    static func buildWithDiagnostics(entries: [ToolRegistryEntry]) -> BuildResult {
        let sortedEntries = entries.sorted { lhs, rhs in
            let lhsRank = entrySortRank(lhs)
            let rhsRank = entrySortRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name < rhs.name
        }

        let registeredCanonicalNames = Set(
            entries.map { normalizeToken($0.name) }
        )

        var aliasToCanonical: [String: String] = [:]
        var droppedAliases: [(alias: String, requestedCanonical: String, reason: String)] = []

        for entry in sortedEntries {
            let canonical = normalizeToken(entry.name)
            aliasToCanonical[canonical] = canonical
        }

        for (alias, canonical) in ToolBuiltinAliases.flattenedAliasToCanonical {
            let normalizedAlias = normalizeToken(alias)
            let normalizedCanonical = normalizeToken(canonical)
            if registeredCanonicalNames.contains(normalizedAlias), normalizedAlias != normalizedCanonical {
                droppedAliases.append((
                    alias: normalizedAlias,
                    requestedCanonical: normalizedCanonical,
                    reason: "registered canonical name wins over builtin alias"
                ))
                continue
            }
            aliasToCanonical[normalizedAlias] = normalizedCanonical
        }

        for entry in sortedEntries {
            let canonical = normalizeToken(entry.name)
            for alias in entry.aliases {
                let normalizedAlias = normalizeToken(alias)
                if registeredCanonicalNames.contains(normalizedAlias), normalizedAlias != canonical {
                    droppedAliases.append((
                        alias: normalizedAlias,
                        requestedCanonical: canonical,
                        reason: "registered canonical name wins over entry alias"
                    ))
                    continue
                }
                aliasToCanonical[normalizedAlias] = canonical
            }
        }

        return BuildResult(
            index: ToolRegistryNameIndex(aliasToCanonical: aliasToCanonical),
            diagnostics: BuildDiagnostics(droppedAliases: droppedAliases)
        )
    }

    /// Trims whitespace and lowercases. Wildcard `*` is preserved as-is.
    static func normalizeToken(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return "*" }
        return trimmed.lowercased()
    }

    func canonical(_ name: String) -> String {
        let normalized = Self.normalizeToken(name)
        if normalized == "*" { return "*" }
        return aliasToCanonical[normalized] ?? normalized
    }

    func listContains(_ list: [String], name: String) -> Bool {
        if list.isEmpty { return false }
        if list.contains(where: { Self.normalizeToken($0) == "*" }) { return true }
        let candidate = canonical(name)
        return list.contains { canonical($0) == candidate }
    }

    func setContains(_ set: Set<String>, name: String) -> Bool {
        if set.isEmpty { return false }
        if set.contains(where: { Self.normalizeToken($0) == "*" }) { return true }
        let candidate = canonical(name)
        return set.contains { canonical($0) == candidate }
    }

    func matchesRegistryName(callName: String, entryName: String) -> Bool {
        canonical(callName) == canonical(entryName)
    }

    func registryName(_ entry: ToolRegistryEntry) -> String {
        Self.normalizeToken(entry.name)
    }

    func policyMatchName(toolName: String, entry: ToolRegistryEntry?) -> String {
        policyMatchNames(toolName: toolName, entry: entry)[0]
    }

    func policyMatchNames(toolName: String, entry: ToolRegistryEntry?) -> [String] {
        if let entry {
            return [registryName(entry)]
        }
        let normalized = Self.normalizeToken(toolName)
        let resolved = canonical(toolName)
        if resolved != normalized {
            return [normalized, resolved]
        }
        return [normalized]
    }

    func normalizedPolicyList(_ list: [String]) -> [String] {
        list.map { canonical($0) }
    }

    func normalizedPolicySet(_ set: Set<String>) -> Set<String> {
        Set(set.map { canonical($0) })
    }

    func resolveEntry(named toolName: String, in entries: [ToolRegistryEntry]) -> ToolRegistryEntry? {
        entries.first { matchesRegistryName(callName: toolName, entryName: $0.name) }
    }
}

private func entrySortRank(_ entry: ToolRegistryEntry) -> Int {
    switch entry.transportKind {
    case .local:
        return 0
    case .mcp, .a2a, .acp:
        return 1
    case .unknown:
        return 2
    }
}
