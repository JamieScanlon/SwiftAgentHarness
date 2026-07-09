import Foundation
import SwiftAgentKit

/// Tags tools from host-injected providers with `group:*` policy tags for registry-backed matching.
struct PluginGroupTaggingToolProvider: ToolProvider {
    let inner: any ToolProvider
    let groupID: String

    init(inner: any ToolProvider, groupID: String) {
        self.inner = inner
        self.groupID = groupID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var name: String { inner.name }

    func availableTools() async -> [ToolDefinition] {
        await inner.availableTools()
    }

    func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        try await inner.executeTool(toolCall)
    }

    func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        var tags = await inner.policyTags(for: definition)
        guard !groupID.isEmpty else { return tags }
        let groupTag = ToolPolicyTag(rawValue: "group:\(groupID)")
        if !tags.contains(where: { $0.rawValue == groupTag.rawValue }) {
            tags.append(groupTag)
        }
        if groupID != "plugins" {
            let pluginsTag = ToolPolicyTag(rawValue: "group:plugins")
            if !tags.contains(where: { $0.rawValue == pluginsTag.rawValue }) {
                tags.append(pluginsTag)
            }
        }
        return tags
    }
}

extension PluginGroupTaggingToolProvider {
    /// Wraps host factory output with plugin group tags (default `plugins`).
    static func wrapHostProviders(
        _ providers: [any ToolProvider],
        pluginGroupID: String?
    ) -> [any ToolProvider] {
        let groupID = pluginGroupID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "plugins"
        return providers.map { PluginGroupTaggingToolProvider(inner: $0, groupID: groupID) }
    }
}
