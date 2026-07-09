import Foundation

/// Registry-maintained membership for `group:*` policy aliases.
struct ToolPolicyGroupIndex: Sendable, Equatable {
    private let membership: [String: Set<String>]
    let nameIndex: ToolRegistryNameIndex

    init(membership: [String: Set<String>], nameIndex: ToolRegistryNameIndex = .builtIn) {
        self.membership = membership
        self.nameIndex = nameIndex
    }

    static let empty = ToolPolicyGroupIndex(membership: [:], nameIndex: .builtIn)

    static func build(from entries: [ToolRegistryEntry]) -> ToolPolicyGroupIndex {
        var membership: [String: Set<String>] = [
            "fs": Self.coreFilesystemToolNames,
            "runtime": Self.coreRuntimeToolNames,
            "web": Self.coreWebToolNames,
        ]

        var mcpTools: Set<String> = []
        var a2aTools: Set<String> = []
        var pluginTools: Set<String> = []
        var customGroups: [String: Set<String>] = [:]

        for entry in entries {
            let registryName = ToolNamePolicyNormalization.registryName(entry)
            switch entry.transportKind {
            case .mcp:
                mcpTools.insert(registryName)
            case .a2a:
                a2aTools.insert(registryName)
            default:
                break
            }
            for tag in entry.groupPolicyTags {
                let groupID = tag.hasPrefix("group:")
                    ? String(tag.dropFirst("group:".count)).lowercased()
                    : tag.lowercased()
                guard !groupID.isEmpty else { continue }
                customGroups[groupID, default: []].insert(registryName)
                pluginTools.insert(registryName)
            }
        }

        membership["mcp"] = mcpTools
        membership["a2a"] = a2aTools
        membership["plugins"] = pluginTools
        for (groupID, tools) in customGroups {
            membership[groupID, default: []].formUnion(tools)
        }

        return ToolPolicyGroupIndex(
            membership: membership,
            nameIndex: ToolRegistryNameIndex.build(entries: entries)
        )
    }

    func contains(groupID: String, toolName: String, nameIndex: ToolRegistryNameIndex? = nil) -> Bool {
        let resolvedIndex = nameIndex ?? self.nameIndex
        let normalizedGroup = groupID.lowercased()
        guard let members = membership[normalizedGroup] else { return false }
        let normalizedName = ToolRegistryNameIndex.normalizeToken(toolName)
        if members.contains(normalizedName) { return true }
        let canonicalName = resolvedIndex.canonical(toolName)
        if canonicalName != normalizedName {
            return members.contains(canonicalName)
        }
        return false
    }

    func tools(in groupID: String) -> Set<String> {
        membership[groupID.lowercased()] ?? []
    }

    private static let coreFilesystemToolNames: Set<String> = [
        "read_file", "write_file", "edit", "glob", "grep",
    ].map { ToolNamePolicyNormalization.canonical($0) }.reduce(into: Set()) { $0.insert($1) }

    private static let coreRuntimeToolNames: Set<String> = [
        "bash", "process",
    ].map { ToolNamePolicyNormalization.canonical($0) }.reduce(into: Set()) { $0.insert($1) }

    private static let coreWebToolNames: Set<String> = [
        "web_fetch", "web_search",
    ].map { ToolNamePolicyNormalization.canonical($0) }.reduce(into: Set()) { $0.insert($1) }
}
