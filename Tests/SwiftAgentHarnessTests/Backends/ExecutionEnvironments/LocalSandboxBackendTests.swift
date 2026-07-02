import Foundation
import Testing
@testable import SwiftAgentHarness

#if os(macOS)
@Suite("Local sandbox backend")
struct LocalSandboxBackendTests {
    @Test("seatbelt profile scopes workspace")
    func seatbeltProfile() throws {
        let root = FileManager.default.temporaryDirectory.path
        let profile = LocalSandboxBackendHandle.seatbeltProfile(workspaceRoot: root, memoryDirectory: nil)
        #expect(profile.contains(root))
        #expect(profile.contains("(deny network*)"))
    }

    @Test("sandbox allows workspace file read")
    func sandboxAllowsWorkspaceRead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hello.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let handle = LocalSandboxBackendHandle(params: CreateSandboxBackendParams(
            sessionKey: "s",
            scopeKey: "agent-a",
            workspaceDir: dir.path,
            agentWorkspaceDir: dir.path,
            config: SandboxConfig(mode: .all, scope: .agent, backend: "local", sandboxingActive: true)
        ))
        let result = try await handle.runShellCommand(params: SandboxBackendCommandParams(script: "cat hello.txt"))
        #expect(result.code == 0)
        #expect(String(data: result.stdout, encoding: .utf8)?.contains("hi") == true)
    }

    @Test("sandboxed exec does not inherit arbitrary host keys")
    func sandboxIsolatesEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let handle = LocalSandboxBackendHandle(params: CreateSandboxBackendParams(
            sessionKey: "s",
            scopeKey: "agent-a",
            workspaceDir: dir.path,
            agentWorkspaceDir: dir.path,
            config: SandboxConfig(mode: .all, scope: .agent, backend: "local", sandboxingActive: true)
        ))
        let result = try await handle.runShellCommand(params: SandboxBackendCommandParams(
            script: "printenv SAH_TEST_OVERLAY",
            env: ["SAH_TEST_OVERLAY": "visible"]
        ))
        #expect(result.code == 0)
        #expect(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "visible")
        let secretResult = try await handle.runShellCommand(params: SandboxBackendCommandParams(
            script: "printenv OPENAI_API_KEY; exit 0"
        ))
        #expect(String(data: secretResult.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    }
}
#endif

#if !os(macOS)
@Suite("Local sandbox unavailable off macOS without bwrap")
struct LocalSandboxUnavailableTests {
    @Test("sandbox unavailable when bwrap missing")
    func unavailable() async {
        let handle = LocalSandboxBackendHandle(params: CreateSandboxBackendParams(
            sessionKey: "s",
            scopeKey: "agent-a",
            workspaceDir: "/tmp",
            agentWorkspaceDir: "/tmp",
            config: SandboxConfig(mode: .all, scope: .agent, backend: "local", sandboxingActive: true)
        ))
        do {
            _ = try await handle.runShellCommand(params: SandboxBackendCommandParams(script: "echo hi"))
            if LocalExecArgv.isSandboxAvailable {
                return
            }
            Issue.record("expected sandbox unavailable")
        } catch SandboxBackendError.sandboxUnavailable {
            #expect(Bool(true))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
#endif
