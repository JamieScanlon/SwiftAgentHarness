import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("ToolExternalContentPolicy")
struct ToolExternalContentPolicyTests {
    private func mcpEntry(named name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .mcpTool),
            source: .mcp
        )
    }

    @Test("web_fetch wraps with security preamble")
    func webFetchWraps() {
        let decision = ToolExternalContentPolicy.resolve(toolName: "web_fetch", entry: nil)
        #expect(decision.shouldWrap)
        #expect(decision.source == .webFetch)
        #expect(decision.includeSecurityPreamble)
    }

    @Test("finish is exempt from wrapping")
    func finishExempt() {
        let decision = ToolExternalContentPolicy.resolve(
            toolName: TerminationToolProvider.finishToolName,
            entry: nil
        )
        #expect(!decision.shouldWrap)
    }

    @Test("MCP tools wrap with security preamble by default")
    func mcpDefaultWraps() {
        let decision = ToolExternalContentPolicy.resolve(
            toolName: "remote_search",
            entry: mcpEntry(named: "remote_search")
        )
        #expect(decision.shouldWrap)
        #expect(decision.source == .api)
        #expect(decision.includeSecurityPreamble)
    }

    @Test("memory_search wraps as known-party without preamble")
    func memorySearchKnownParty() {
        let decision = ToolExternalContentPolicy.resolve(
            toolName: MemorySearchToolProvider.searchToolName,
            entry: nil
        )
        #expect(decision.shouldWrap)
        #expect(decision.source == .api)
        #expect(!decision.includeSecurityPreamble)
    }

    @Test("unknown local tools wrap with preamble")
    func unknownLocalWraps() {
        let decision = ToolExternalContentPolicy.resolve(toolName: "custom_probe", entry: nil)
        #expect(decision.shouldWrap)
        #expect(decision.includeSecurityPreamble)
    }
}
