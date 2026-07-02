import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Background process session scope (SEC-009)", .serialized)
struct BackgroundProcessSessionScopeTests {
    private let sessionA = "session-a"
    private let sessionB = "session-b"

    @Test("authorized session can poll, snapshot, send keys, and kill")
    func authorizedSessionOperationsSucceed() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "echo hello; sleep 5"],
            env: [:],
            cwd: nil
        )
        var sawOutput = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let snap = await registry.snapshot(id: id, sessionSlug: sessionA),
               snap.output.contains("hello") {
                sawOutput = true
                break
            }
        }
        #expect(sawOutput)

        let polled = await registry.poll(id: id, sessionSlug: sessionA)
        #expect(polled != nil)

        let idForCat = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "cat"],
            env: [:],
            cwd: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await registry.sendKeys(id: idForCat, sessionSlug: sessionA, data: Data("ping\n".utf8))

        #expect(await registry.kill(id: idForCat, sessionSlug: sessionA))
        await registry.kill(id: id, sessionSlug: sessionA)
    }

    @Test("foreign session cannot poll, snapshot, send keys, or kill")
    func foreignSessionDenied() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: sessionA,
            argv: ["/bin/bash", "-c", "echo secret; sleep 10"],
            env: [:],
            cwd: nil
        )

        var ownerSawOutput = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let snap = await registry.snapshot(id: id, sessionSlug: sessionA),
               snap.output.contains("secret") {
                ownerSawOutput = true
                break
            }
        }
        #expect(ownerSawOutput)

        #expect(await registry.poll(id: id, sessionSlug: sessionB) == nil)
        #expect(await registry.snapshot(id: id, sessionSlug: sessionB) == nil)
        #expect(await registry.kill(id: id, sessionSlug: sessionB) == false)

        do {
            try await registry.sendKeys(id: id, sessionSlug: sessionB, data: Data("pwn\n".utf8))
            Issue.record("Expected sendKeys to fail for foreign session")
        } catch let error as SandboxBackendError {
            if case .commandFailed(let reason) = error {
                #expect(reason.contains("process not found"))
            } else {
                Issue.record("Unexpected SandboxBackendError: \(error)")
            }
        }

        #expect(await registry.snapshot(id: id, sessionSlug: sessionA) != nil)
        await registry.kill(id: id, sessionSlug: sessionA)
    }

    @Test("executor scopes poll and kill to runtime sessionKey")
    func executorScopesToSessionKey() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec009-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let execRuntime = ExecRuntimeService(workspaceRoot: base.path)
        let contextA = ExecRuntimeContext(sessionKey: sessionA, agentID: "agent-a", isMainSession: true)
        let contextB = ExecRuntimeContext(sessionKey: sessionB, agentID: "agent-b", isMainSession: true)
        let executorA = LocalSandboxBashExecutor(execRuntime: execRuntime, runtimeContext: contextA)
        let executorB = LocalSandboxBashExecutor(execRuntime: execRuntime, runtimeContext: contextB)

        let started = try await executorA.runBash(
            command: "echo owner-output; sleep 10",
            runInBackground: true
        )
        guard let taskID = started.backgroundTaskID else {
            Issue.record("Expected background task ID")
            return
        }

        var ownerPoll: (status: String, stdout: String)?
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let poll = await executorA.pollProcess(taskID: taskID), poll.stdout.contains("owner-output") {
                ownerPoll = poll
                break
            }
        }
        #expect(ownerPoll != nil)

        #expect(await executorB.pollProcess(taskID: taskID) == nil)
        #expect(await executorB.terminalSnapshot(taskID: taskID) == nil)
        #expect(await executorB.killProcess(taskID: taskID) == false)
        #expect(await executorA.pollProcess(taskID: taskID) != nil)
        _ = await executorA.killProcess(taskID: taskID)
    }
}
