import Foundation

enum ToolPolicyNameMatcher {
    static func matches(
        rule: ToolPolicyRule,
        toolName: String,
        entry: ToolRegistryEntry?,
        groupIndex: ToolPolicyGroupIndex,
        nameIndex: ToolRegistryNameIndex? = nil
    ) -> Bool {
        let resolvedIndex = nameIndex ?? groupIndex.nameIndex
        switch rule {
        case .wildcard:
            return true
        case .bareName(let name):
            return policyMatchNames(toolName: toolName, entry: entry, nameIndex: resolvedIndex).contains(name)
        case .nameGlob(let pattern):
            return policyMatchNames(toolName: toolName, entry: entry, nameIndex: resolvedIndex).contains { candidate in
                flatGlobMatches(pattern: pattern, value: candidate)
            }
        case .groupAlias(let groupID):
            return policyMatchNames(toolName: toolName, entry: entry, nameIndex: resolvedIndex).contains { candidate in
                groupIndex.contains(groupID: groupID, toolName: candidate, nameIndex: resolvedIndex)
            }
        case .argumentMatcher:
            return false
        }
    }

    static func listMatches(
        rules: [ToolPolicyRule],
        toolName: String,
        entry: ToolRegistryEntry? = nil,
        groupIndex: ToolPolicyGroupIndex = .empty,
        nameIndex: ToolRegistryNameIndex? = nil
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        if rules.contains(.wildcard) { return true }
        let nameRules = rules.filter(\.isNameLevelRule)
        guard !nameRules.isEmpty else { return false }
        return nameRules.contains { matches(rule: $0, toolName: toolName, entry: entry, groupIndex: groupIndex, nameIndex: nameIndex) }
    }

    /// Evaluates allowlist semantics: nil = no opinion (true); empty = closed world (false).
    static func allowlistPermits(
        rules: [ToolPolicyRule]?,
        toolName: String,
        entry: ToolRegistryEntry? = nil,
        groupIndex: ToolPolicyGroupIndex = .empty,
        nameIndex: ToolRegistryNameIndex? = nil
    ) -> Bool {
        guard let rules else { return true }
        if rules.isEmpty { return false }
        return listMatches(rules: rules, toolName: toolName, entry: entry, groupIndex: groupIndex, nameIndex: nameIndex)
    }

    static func denylistBlocks(
        rules: [ToolPolicyRule],
        toolName: String,
        entry: ToolRegistryEntry? = nil,
        groupIndex: ToolPolicyGroupIndex = .empty,
        nameIndex: ToolRegistryNameIndex? = nil
    ) -> Bool {
        listMatches(rules: rules, toolName: toolName, entry: entry, groupIndex: groupIndex, nameIndex: nameIndex)
    }

    private static func policyMatchNames(
        toolName: String,
        entry: ToolRegistryEntry?,
        nameIndex: ToolRegistryNameIndex
    ) -> [String] {
        ToolNamePolicyNormalization.policyMatchNames(toolName: toolName, entry: entry, index: nameIndex)
    }

    private static func flatGlobMatches(pattern: String, value: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("/") {
            return WorkspaceGlobMatcher.matches(relativePath: value, pattern: pattern)
        }
        return WorkspaceGlobMatcher.matches(relativePath: value, pattern: pattern)
    }
}
