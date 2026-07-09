import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Tool result spill")
struct ToolResultSpillTests {
    private func makeHarness(root: URL) throws -> LocalHarnessSessionPersistence {
        try LocalHarnessSessionPersistence(root: root, agentId: "test-agent")
    }

    private func spillContext(
        conversationID: UUID,
        persistence: any HarnessSessionPersistence,
        entry: ToolRegistryEntry? = nil
    ) -> ToolResultFormattingSpillContext {
        ToolResultFormattingSpillContext(
            conversationID: conversationID,
            toolName: entry?.name ?? "bash",
            entry: entry,
            spillWriter: HarnessSessionPersistenceSpillWriter(persistence: persistence)
        )
    }

    @Test("oversized runtime result spills to disk with preview envelope")
    func oversizedResultSpills() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = try makeHarness(root: root)
        let conversationID = UUID()
        let content = String(repeating: "x", count: 600)
        let result = ToolResult(
            success: true,
            content: content,
            metadata: .object([:]),
            toolCallId: "call-spill-1"
        )
        let config = ToolResultFormattingConfiguration(
            enabled: true,
            spillEnabled: true,
            spillPreviewMaxBytes: 64,
            defaultMaxResultSizeBeforeSpill: 128
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: spillContext(conversationID: conversationID, persistence: harness)
        )
        #expect(output.content.contains(ToolResultSpillEnvelope.marker))
        #expect(output.content.contains("full_output_path:"))
        #expect(!output.content.contains("[tool result truncated]"))
        let spillPath = SessionPersistenceLayout.toolResultSpillFileURL(
            root: root,
            agentId: "test-agent",
            conversationId: conversationID,
            toolCallId: "call-spill-1"
        )
        #expect(FileManager.default.fileExists(atPath: spillPath.path))
        let spilled = try String(contentsOf: spillPath, encoding: .utf8)
        #expect(spilled == content)
    }

    @Test("re-spill for same tool call id is idempotent")
    func idempotentRespill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = try makeHarness(root: root)
        let conversationID = UUID()
        let content = String(repeating: "y", count: 500)
        let result = ToolResult(
            success: true,
            content: content,
            metadata: .object([:]),
            toolCallId: "call-idem"
        )
        let config = ToolResultFormattingConfiguration(
            spillEnabled: true,
            spillPreviewMaxBytes: 32,
            defaultMaxResultSizeBeforeSpill: 64
        )
        let context = spillContext(conversationID: conversationID, persistence: harness)
        let first = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: context
        )
        let second = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: context
        )
        #expect(first.content == second.content)
    }

    @Test("read_file exempt tools do not spill")
    func readFileExemptDoesNotSpill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-exempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = try makeHarness(root: root)
        let conversationID = UUID()
        let entry = ToolRegistryEntry(
            definition: ToolDefinition(name: "read_file", description: "", parameters: [], type: .function),
            source: .local,
            effectClass: .readOnly
        )
        let content = String(repeating: "z", count: 500)
        let result = ToolResult(success: true, content: content, metadata: .object([:]), toolCallId: "call-read")
        let config = ToolResultFormattingConfiguration(
            spillEnabled: true,
            defaultMaxResultSizeBeforeSpill: 64,
            runtimeMaxBytes: 64
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config,
            spillContext: spillContext(conversationID: conversationID, persistence: harness, entry: entry)
        )
        #expect(!output.content.contains(ToolResultSpillEnvelope.marker))
        #expect(output.content.contains("[tool result truncated]"))
    }

    @Test("read_file can recover spilled output path")
    func readFileRecoversSpillPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID()
        let harness = try makeHarness(root: root)
        let fullContent = String(repeating: "recover-me-", count: 80)
        let write = try harness.putToolResultSpillIfNeeded(
            conversationID: conversationID,
            toolCallId: "recover-call",
            content: fullContent
        )
        #expect(write != nil)
        let spillPath = try #require(write?.fileURL.path)

        let provider = WorkspaceFilesystemToolProvider(
            workspaceRoot: root.path,
            execRuntime: ExecRuntimeService(workspaceRoot: root.path),
            runtimeContext: ExecRuntimeContext(
                sessionKey: conversationID.uuidString,
                agentID: "test-agent",
                isMainSession: true
            ),
            sessionStoreRoot: root,
            sessionAgentId: "test-agent",
            conversationID: conversationID
        )
        let toolCall = ToolCall(
            name: WorkspaceFilesystemToolProvider.readFileToolName,
            arguments: .object(["file_path": .string(spillPath)]),
            id: "read-spill"
        )
        let readResult = try await provider.executeTool(toolCall)
        #expect(readResult.success)
        #expect(readResult.content == fullContent)
        #expect(readResult.content.count > 64)
    }

    @Test("spill disabled falls back to truncation")
    func spillDisabledFallsBack() {
        let content = String(repeating: "a", count: 200)
        let result = ToolResult(success: true, content: content, metadata: .object([:]), toolCallId: "call-fallback")
        let config = ToolResultFormattingConfiguration(
            enabled: true,
            spillEnabled: false,
            defaultMaxResultSizeBeforeSpill: 32,
            runtimeMaxBytes: 64
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .runtime,
            configuration: config
        )
        #expect(!output.content.contains(ToolResultSpillEnvelope.marker))
        #expect(output.content.contains("[tool result truncated]"))
    }

    @Test("persistence stage preserves spill envelope without lossy trim")
    func persistencePreservesSpillEnvelope() {
        let envelope = ToolResultSpillEnvelope.make(
            preview: "preview-only",
            spillPath: "/tmp/spill.txt",
            originalByteCount: 9_999,
            toolCallId: "persist-call"
        )
        let result = ToolResult(success: true, content: envelope, metadata: .object([:]), toolCallId: "persist-call")
        let config = ToolResultFormattingConfiguration(
            enabled: true,
            persistenceMaxCharacters: 16,
            persistenceMaxBytes: 32
        )
        let output = ToolResultFormattingStack.apply(
            result: result,
            stage: .persistence,
            configuration: config
        )
        #expect(output.content.contains(ToolResultSpillEnvelope.marker))
        #expect(output.content.contains("full_output_path:"))
        #expect(!output.content.contains("[tool result truncated]"))
    }
}
