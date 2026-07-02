import Foundation

protocol BashShellRunning: Sendable {
    func runBash(
        command: String,
        runInBackground: Bool,
        usePty: Bool,
        approvalContextLines: [String]
    ) async throws -> ExecSupervisorResult
}

struct LocalSandboxBashExecutor: BashShellRunning, Sendable {
    let execRuntime: ExecRuntimeService
    let runtimeContext: ExecRuntimeContext

    func runBash(
        command: String,
        runInBackground: Bool = false,
        usePty: Bool = false,
        approvalContextLines: [String] = []
    ) async throws -> ExecSupervisorResult {
        try await execRuntime.runShell(
            command: command,
            context: runtimeContext,
            runInBackground: runInBackground,
            usePty: usePty,
            approvalContextLines: approvalContextLines
        )
    }

    func pollProcess(taskID: String) async -> (status: String, stdout: String)? {
        guard let session = await BashProcessRegistry.shared.poll(id: taskID, sessionSlug: runtimeContext.sessionKey) else {
            return nil
        }
        var stdout = String(decoding: session.pendingStdout, as: UTF8.self)
        var status = session.exitCode.map { "exit \($0)" } ?? "running"
        if session.stdoutTruncated {
            let dropped = max(0, session.totalStdoutBytes - BashProcessRegistry.maxLiveBufferBytes)
            status += " (output truncated, \(dropped) bytes dropped)"
            if !stdout.isEmpty { stdout += "\n" }
            stdout += "[log truncated: \(dropped) bytes of earlier output dropped]"
        }
        return (status, stdout)
    }

    func terminalSnapshot(taskID: String) async -> (output: String, truncated: Bool, exitCode: Int32?)? {
        guard let snap = await BashProcessRegistry.shared.snapshot(id: taskID, sessionSlug: runtimeContext.sessionKey) else { return nil }
        var output = snap.output
        if snap.truncated {
            output += "\n[log truncated: earlier output dropped]"
        }
        return (output, snap.truncated, snap.exitCode)
    }

    @discardableResult
    func killProcess(taskID: String) async -> Bool {
        await BashProcessRegistry.shared.kill(id: taskID, sessionSlug: runtimeContext.sessionKey)
    }

    func sendKeys(taskID: String, keys: String) async throws {
        try await BashProcessRegistry.shared.sendKeys(
            id: taskID,
            sessionSlug: runtimeContext.sessionKey,
            data: Data(keys.utf8)
        )
    }
}
