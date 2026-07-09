import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool registry result formatting policy")
struct ToolRegistryResultFormattingPolicyTests {
    @Test("fail-closed default skips no trims without exact-content tag")
    func failClosedDefault() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
            source: .local
        )
        #expect(
            !ToolRegistryResultFormattingPolicy.skipsLossyContentTrim(
                entry: entry,
                toolName: "bash",
                stage: .runtime
            )
        )
        #expect(
            !ToolRegistryResultFormattingPolicy.isCompactionProtected(entry: entry, toolName: "bash")
        )
    }

    @Test("exact-content tag skips runtime and persistence only")
    func exactContentStagePolarity() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local,
            policyTags: [.exactContentObservation]
        )
        #expect(
            ToolRegistryResultFormattingPolicy.skipsLossyContentTrim(
                entry: entry,
                toolName: "read_file",
                stage: .runtime
            )
        )
        #expect(
            ToolRegistryResultFormattingPolicy.skipsLossyContentTrim(
                entry: entry,
                toolName: "read_file",
                stage: .persistence
            )
        )
        #expect(
            !ToolRegistryResultFormattingPolicy.skipsLossyContentTrim(
                entry: entry,
                toolName: "read_file",
                stage: .compaction
            )
        )
    }

    @Test("delegate tools auto-tag exact-content and compaction-protected")
    func delegateAutoTags() {
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "delegate_researcher", description: "", parameters: [], type: .function),
            source: .local
        )
        #expect(entry.policyTags.contains(.exactContentObservation))
        #expect(entry.policyTags.contains(.compactionProtected))
        #expect(ToolRegistryResultFormattingPolicy.isCompactionProtected(entry: entry, toolName: entry.name))
    }

    @Test("delegate prefix is compaction-protected without registry entry")
    func delegatePrefixProtectedForPruning() {
        #expect(
            ToolRegistryResultFormattingPolicy.isCompactionProtectedForPruning(
                toolName: "delegate_coder"
            )
        )
        #expect(
            !ToolRegistryResultFormattingPolicy.isCompactionProtectedForPruning(
                toolName: "read_file"
            )
        )
    }
}
