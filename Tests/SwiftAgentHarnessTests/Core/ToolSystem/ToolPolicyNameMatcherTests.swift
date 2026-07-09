import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyNameMatcher")
struct ToolPolicyNameMatcherTests {
    private func index(with entries: [ToolRegistryEntry]) -> ToolPolicyGroupIndex {
        ToolPolicyGroupIndex.build(from: entries)
    }

    private func mcpEntry(_ name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .mcpTool),
            source: .mcp,
            transportKind: .mcp
        )
    }

    @Test("group:mcp matches dynamic MCP tool names")
    func groupMCP() {
        let groupIndex = index(with: [mcpEntry("search"), mcpEntry("fetch_data")])
        let rules = [ToolPolicyRule.groupAlias("mcp")]
        #expect(ToolPolicyNameMatcher.listMatches(rules: rules, toolName: "search", groupIndex: groupIndex))
        #expect(ToolPolicyNameMatcher.listMatches(rules: rules, toolName: "read_file", groupIndex: groupIndex) == false)
    }

    @Test("name glob mcp_* matches prefixed names")
    func nameGlob() {
        let rules = [ToolPolicyRule.nameGlob("mcp_*")]
        #expect(ToolPolicyNameMatcher.listMatches(rules: rules, toolName: "mcp_search"))
        #expect(ToolPolicyNameMatcher.listMatches(rules: rules, toolName: "search") == false)
    }

    @Test("deny-wins via denylistBlocks")
    func denylist() {
        let rules = [ToolPolicyRule.groupAlias("mcp")]
        let groupIndex = index(with: [mcpEntry("search")])
        #expect(ToolPolicyNameMatcher.denylistBlocks(rules: rules, toolName: "search", groupIndex: groupIndex))
    }

    @Test("argument matcher ignored at name level")
    func argumentMatcherIgnored() {
        let rules = [ToolPolicyRule.argumentMatcher(toolName: "bash", pattern: "npm run *")]
        #expect(ToolPolicyNameMatcher.listMatches(rules: rules, toolName: "bash") == false)
    }

    @Test("registry entry identity is not remapped by legacy aliases")
    func registryEntryIdentity() {
        let mcpSearch = mcpEntry("search")
        let groupIndex = index(with: [mcpSearch])
        let fsRules = [ToolPolicyRule.groupAlias("fs")]
        #expect(
            ToolPolicyNameMatcher.listMatches(
                rules: fsRules,
                toolName: "search",
                entry: mcpSearch,
                groupIndex: groupIndex
            ) == false
        )
    }
}
