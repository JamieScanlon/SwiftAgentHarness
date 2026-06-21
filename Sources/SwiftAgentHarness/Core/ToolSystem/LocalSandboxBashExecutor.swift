import Foundation

struct LocalSandboxBashExecutor: Sendable {
    let execRuntime: ExecRuntimeService
    let runtimeContext: ExecRuntimeContext

    func runBash(command: String, runInBackground: Bool = false, usePty: Bool = false) async throws -> ExecSupervisorResult {
        try await execRuntime.runShell(
            command: command,
            context: runtimeContext,
            runInBackground: runInBackground,
            usePty: usePty
        )
    }

    func pollProcess(taskID: String) async -> (status: String, stdout: String)? {
        guard let session = await BashProcessRegistry.shared.poll(id: taskID) else {
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
        guard let snap = await BashProcessRegistry.shared.snapshot(id: taskID) else { return nil }
        var output = snap.output
        if snap.truncated {
            output += "\n[log truncated: earlier output dropped]"
        }
        return (output, snap.truncated, snap.exitCode)
    }

    func killProcess(taskID: String) async {
        await BashProcessRegistry.shared.kill(id: taskID)
    }
}
