import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FS bridge stat parsing")
struct FsBridgeStatParseTests {
    @Test("parses regular file metadata")
    func parsesFile() {
        let result = SandboxBackendCommandResult(
            stdout: Data("0\t42\n".utf8),
            stderr: Data(),
            code: 0
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat == SandboxFsStat(isDirectory: false, size: 42, exists: true))
    }

    @Test("parses directory metadata")
    func parsesDirectory() {
        let result = SandboxBackendCommandResult(
            stdout: Data("1\t96\n".utf8),
            stderr: Data(),
            code: 0
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat == SandboxFsStat(isDirectory: true, size: 96, exists: true))
    }

    @Test("non-zero exit yields missing path")
    func missingPath() {
        let result = SandboxBackendCommandResult(stdout: Data(), stderr: Data(), code: 1)
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat == SandboxFsStat(isDirectory: false, size: 0, exists: false))
    }

    @Test("malformed stdout yields missing path")
    func malformedOutput() {
        let result = SandboxBackendCommandResult(
            stdout: Data("not-a-stat-line\n".utf8),
            stderr: Data(),
            code: 0
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat == SandboxFsStat(isDirectory: false, size: 0, exists: false))
    }
}

#if os(macOS)
@Suite("FS bridge stat shell script")
struct FsBridgeStatShellTests {
    private func makeHandle(workspace: String, scopeKey: String = "stat-test") -> LocalSandboxBackendHandle {
        LocalSandboxBackendHandle(params: CreateSandboxBackendParams(
            sessionKey: "s",
            scopeKey: scopeKey,
            workspaceDir: workspace,
            agentWorkspaceDir: workspace,
            config: SandboxConfig(mode: .all, scope: .agent, backend: "local", sandboxingActive: true)
        ))
    }

    @Test("stat script reports regular file size")
    func statRegularFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-stat-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileName = "hello.txt"
        let content = "hello-stat"
        try content.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

        let handle = makeHandle(workspace: dir.path, scopeKey: "stat-file-\(UUID().uuidString)")
        let result = try await handle.runShellCommand(
            params: SandboxFsBridgeShellCommands.stat(rel: fileName)
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat.exists)
        #expect(!stat.isDirectory)
        #expect(stat.size == Int64(content.utf8.count))
    }

    @Test("stat script reports directory")
    func statDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-stat-dir-\(UUID().uuidString)", isDirectory: true)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handle = makeHandle(workspace: dir.path, scopeKey: "stat-dir-\(UUID().uuidString)")
        let result = try await handle.runShellCommand(
            params: SandboxFsBridgeShellCommands.stat(rel: "nested")
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(stat.exists)
        #expect(stat.isDirectory)
    }

    @Test("stat script reports missing path")
    func statMissingPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-stat-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let handle = makeHandle(workspace: dir.path, scopeKey: "stat-missing-\(UUID().uuidString)")
        let result = try await handle.runShellCommand(
            params: SandboxFsBridgeShellCommands.stat(rel: "does-not-exist.txt")
        )
        let stat = SandboxFsStat.parse(from: result)
        #expect(!stat.exists)
        #expect(!stat.isDirectory)
        #expect(stat.size == 0)
    }
}
#endif
