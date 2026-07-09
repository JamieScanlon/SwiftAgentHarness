import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolPolicyGroupIndex")
struct ToolPolicyGroupIndexTests {
    private func entry(
        name: String,
        transport: ToolRegistryEntry.TransportKind = .local,
        groupTags: Set<String> = []
    ) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: transport == .mcp ? .mcp : .local,
            transportKind: transport,
            groupPolicyTags: groupTags
        )
    }

    @Test("core fs group contains filesystem tools")
    func coreFSGroup() {
        let index = ToolPolicyGroupIndex.build(from: [
            entry(name: "read_file"),
            entry(name: "write_file"),
            entry(name: "bash"),
        ])
        #expect(index.contains(groupID: "fs", toolName: "read_file"))
        #expect(index.contains(groupID: "fs", toolName: "write_file"))
        #expect(index.contains(groupID: "fs", toolName: "bash") == false)
        #expect(index.contains(groupID: "runtime", toolName: "bash"))
    }

    @Test("mcp transport group")
    func mcpGroup() {
        let index = ToolPolicyGroupIndex.build(from: [
            entry(name: "search", transport: .mcp),
            entry(name: "read_file"),
        ])
        #expect(index.contains(groupID: "mcp", toolName: "search"))
        #expect(index.contains(groupID: "mcp", toolName: "read_file") == false)
    }

    @Test("custom plugin group tag")
    func pluginGroupTag() {
        let index = ToolPolicyGroupIndex.build(from: [
            entry(name: "host_tool", groupTags: ["group:myPlugin"]),
        ])
        #expect(index.contains(groupID: "myplugin", toolName: "host_tool"))
        #expect(index.contains(groupID: "plugins", toolName: "host_tool"))
    }
}
