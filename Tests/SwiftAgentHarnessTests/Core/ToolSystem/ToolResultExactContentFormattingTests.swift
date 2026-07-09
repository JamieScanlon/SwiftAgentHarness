import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

@Suite("Tool result exact-content formatting")
struct ToolResultExactContentFormattingTests {
    private func exactContentEntry(name: String) -> ToolRegistryEntry {
        ToolRegistryEntry(
            definition: ToolDefinition(name: name, description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly,
            policyTags: [.exactContentObservation]
        )
    }

    private func spillContext(entry: ToolRegistryEntry) throws -> ToolResultFormattingSpillContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("exact-content-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ToolResultFormattingSpillContext(
            conversationID: UUID(),
            toolName: entry.name,
            entry: entry,
            spillWriter: HarnessSessionPersistenceSpillWriter(
                persistence: try LocalHarnessSessionPersistence(root: root, agentId: "test-agent")
            )
        )
    }

    @Test("exact-content read_file bypasses runtime lossy trim")
    func readFileBypassesRuntimeTrim() throws {
        let content = String(repeating: "r", count: 500)
        let result = ToolResult(success: true, content: content, metadata: .object([:]), toolCallId: "call-read")
        let config = ToolResultFormattingConfiguration(
            runtimeMaxCharacters: 64,
            runtimeMaxBytes: 64,
            maxLines: 3,
            truncationMarker: "[tool result truncated]"
        )
        let entry = exactContentEntry(name: "read_file")
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: try spillContext(entry: entry)
        )
        #expect(output.content == content)
        #expect(!output.content.contains("[tool result truncated]"))
    }

    @Test("exact-content get_plan bypasses persistence metadata trim")
    func getPlanBypassesMetadataTrim() throws {
        let oversizedMetadata: JSON = .object([
            "payload": .string(String(repeating: "p", count: 4_000)),
        ])
        let result = ToolResult(
            success: true,
            content: String(repeating: "plan", count: 200),
            metadata: oversizedMetadata,
            toolCallId: "call-plan"
        )
        let config = ToolResultFormattingConfiguration(
            persistenceMetadataMaxBytes: 120,
            metadataPlaceholder: "[meta omitted]"
        )
        let entry = exactContentEntry(name: "get_plan")
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .persistence,
            configuration: config,
            spillContext: try spillContext(entry: entry)
        )
        #expect(output.content == result.content)
        guard case .object(let object) = output.metadata else {
            Issue.record("Expected metadata object preserved")
            return
        }
        if case .string(let payload) = object["payload"] {
            #expect(payload.count == 4_000)
        } else {
            Issue.record("Expected payload preserved")
        }
    }

    @Test("bash remains lossy-trimmed at runtime")
    func bashStillTruncates() throws {
        let content = String(repeating: "b", count: 500)
        let result = ToolResult(success: true, content: content, metadata: .object([:]), toolCallId: "call-bash")
        let config = ToolResultFormattingConfiguration(
            runtimeMaxBytes: 64,
            truncationMarker: "[tool result truncated]"
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: try spillContext(entry: ToolRegistryEntry(
                definition: ToolDefinition(name: "bash", description: "", parameters: [], type: .function),
                source: .local
            ))
        )
        #expect(output.content.contains("[tool result truncated]"))
    }

    @Test("compaction formatting stage still trims exact-content tools")
    func compactionStageStillTrims() throws {
        let content = String(repeating: "c", count: 500)
        let result = ToolResult(success: true, content: content, metadata: .object([:]), toolCallId: "call-compact")
        let config = ToolResultFormattingConfiguration(
            compactionMaxBytes: 64,
            compactionTruncationMarker: "[compaction truncated]"
        )
        let entry = exactContentEntry(name: "read_file")
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .compaction,
            configuration: config,
            spillContext: try spillContext(entry: entry)
        )
        #expect(output.content.contains("[compaction truncated]"))
    }
}
