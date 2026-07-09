import EasyJSON
import Foundation

enum ToolPolicyCallMatcher {
    static func matches(
        rule: ToolPolicyRule,
        entry: ToolRegistryEntry,
        arguments: JSON,
        groupIndex: ToolPolicyGroupIndex,
        nameIndex: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        switch rule {
        case .wildcard:
            return true
        case .bareName(let name):
            return nameIndex.registryName(entry) == name
        case .nameGlob(let pattern):
            return ToolPolicyNameMatcher.listMatches(
                rules: [.nameGlob(pattern)],
                toolName: entry.name,
                groupIndex: groupIndex,
                nameIndex: nameIndex
            )
        case .groupAlias(let groupID):
            return groupIndex.contains(
                groupID: groupID,
                toolName: nameIndex.registryName(entry),
                nameIndex: nameIndex
            )
        case .argumentMatcher(let toolName, let pattern):
            guard nameIndex.registryName(entry) == toolName else {
                return false
            }
            if ToolPolicyArgumentExtractor.patternContainsTraversal(pattern) {
                return false
            }
            let values = ToolPolicyArgumentExtractor.extractedValues(
                toolName: entry.name,
                arguments: arguments
            )
            guard !values.isEmpty else { return false }
            return values.allSatisfy { value in
                matchesArgumentPattern(pattern: pattern, toolName: toolName, value: value, nameIndex: nameIndex)
            }
        }
    }

    static func listMatches(
        rules: [ToolPolicyRule],
        entry: ToolRegistryEntry,
        arguments: JSON,
        groupIndex: ToolPolicyGroupIndex,
        nameIndex: ToolRegistryNameIndex = .builtIn
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        if rules.contains(.wildcard) { return true }
        return rules.contains { matches(rule: $0, entry: entry, arguments: arguments, groupIndex: groupIndex, nameIndex: nameIndex) }
    }

    private static func matchesArgumentPattern(pattern: String, toolName: String, value: String, nameIndex: ToolRegistryNameIndex = .builtIn) -> Bool {
        let canonical = nameIndex.canonical(toolName)
        switch canonical {
        case "bash":
            return matchesShellPattern(pattern: pattern, command: value)
        case "read_file", "write_file", "edit":
            return WorkspaceGlobMatcher.matches(relativePath: value, pattern: pattern)
        case "web_fetch":
            return WorkspaceGlobMatcher.matches(relativePath: value, pattern: pattern)
        default:
            return WorkspaceGlobMatcher.matches(relativePath: value, pattern: pattern)
        }
    }

    private static func matchesShellPattern(pattern: String, command: String) -> Bool {
        if pattern.contains("/") {
            return WorkspaceGlobMatcher.matches(relativePath: command, pattern: pattern)
        }
        if let grantName = ExecApprovalGrantCommandName.durableGrantCommandName(from: command) {
            if WorkspaceGlobMatcher.matches(relativePath: grantName, pattern: pattern) {
                return true
            }
            return WorkspaceGlobMatcher.matches(relativePath: command, pattern: pattern)
        }
        return WorkspaceGlobMatcher.matches(relativePath: command, pattern: pattern)
    }
}
