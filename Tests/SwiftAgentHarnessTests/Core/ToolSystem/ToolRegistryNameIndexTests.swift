import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolRegistryNameIndex")
struct ToolRegistryNameIndexTests {
    @Test("builtIn index matches P1 legacy alias expectations")
    func builtInLegacyAliases() {
        let index = ToolRegistryNameIndex.builtIn
        #expect(index.canonical("read") == "read_file")
        #expect(index.canonical("terminal") == "bash")
        #expect(index.canonical("search_files") == "grep")
        #expect(index.canonical("web-search") == "web_search")
        #expect(index.canonical("fetch") == "web_fetch")
    }

    @Test("registry entry custom alias resolves to canonical name")
    func registryEntryCustomAlias() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local,
            aliases: ["old_shell"]
        )
        let index = ToolRegistryNameIndex.build(entries: [entry])
        #expect(index.canonical("old_shell") == "bash")
    }

    @Test("registered MCP search prevents builtin search to grep remap")
    func mcpSearchCollision() {
        let grep = ToolRegistryEntry(
            definition: ToolDefinition(name: "grep", description: "", parameters: [], type: .function),
            source: .local
        )
        let mcpSearch = ToolRegistryEntry(
            definition: ToolDefinition(name: "search", description: "", parameters: [], type: .function),
            source: .mcp
        )
        let index = ToolRegistryNameIndex.build(entries: [grep, mcpSearch])
        #expect(index.canonical("search") == "search")
        #expect(index.canonical("search_files") == "grep")
    }

    @Test("resolveEntry finds entry by legacy call name")
    func resolveEntryByLegacyName() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local
        )
        let index = ToolRegistryNameIndex.build(entries: [entry])
        let resolved = index.resolveEntry(named: "read", in: [entry])
        #expect(resolved?.name == "read_file")
    }

    @Test("policyMatchNames preserves registry entry identity")
    func policyMatchNamesEntryIdentity() {
        let mcpSearch = ToolRegistryEntry(
            definition: ToolDefinition(name: "search", description: "", parameters: [], type: .function),
            source: .mcp
        )
        let index = ToolRegistryNameIndex.build(entries: [mcpSearch])
        #expect(index.policyMatchNames(toolName: "search", entry: mcpSearch) == ["search"])
    }

    @Test("build diagnostics report dropped builtin alias when canonical name is registered")
    func buildDiagnosticsDroppedAlias() {
        let mcpSearch = ToolRegistryEntry(
            definition: ToolDefinition(name: "search", description: "", parameters: [], type: .function),
            source: .mcp
        )
        let build = ToolRegistryNameIndex.buildWithDiagnostics(entries: [mcpSearch])
        #expect(build.diagnostics.droppedAliases.contains { $0.alias == "search" && $0.requestedCanonical == "grep" })
        #expect(build.index.canonical("search") == "search")
    }

    @Test("ConversationExplicitToolPolicy decode normalizes legacy tool names")
    func conversationExplicitToolPolicyDecode() throws {
        let json = """
        {"kind":"allowlist","tools":["read"],"skills":[]}
        """
        let data = Data(json.utf8)
        let policy = try JSONDecoder().decode(ConversationExplicitToolPolicy.self, from: data)
        guard case .allowlist(let tools, _) = policy else {
            Issue.record("Expected allowlist")
            return
        }
        #expect(tools == ["read_file"])
    }
}
