import Foundation

public struct ExecSupervisorResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let backgroundTaskID: String?
}

public enum ExecSupervisor {
    public static func runForeground(
        sessionSlug: String,
        handle: any SandboxBackendHandle,
        params: SandboxBuildExecSpecParams,
        budgetSeconds: TimeInterval? = nil,
        timeoutSeconds: TimeInterval? = nil,
        registry: BashProcessRegistry = .shared
    ) async throws -> ExecSupervisorResult {
        let spec = try await handle.buildExecSpec(params: params)
        if let budgetSeconds {
            let budgetResult = try await registry.runWithForegroundBudget(
                sessionSlug: sessionSlug,
                argv: spec.argv,
                env: spec.env,
                cwd: spec.cwd,
                budgetSeconds: budgetSeconds,
                usePty: spec.usePty,
                inheritHostEnvironment: spec.inheritHostEnvironment,
                timeoutSeconds: timeoutSeconds
            )
            switch budgetResult.outcome {
            case .completed(let stdout, let stderr, let exitCode):
                let status: SandboxExecStatus = exitCode == 0 ? .completed : .failed
                try await handle.finalizeExec(params: SandboxFinalizeExecParams(status: status, exitCode: exitCode, timedOut: false))
                return ExecSupervisorResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: false, backgroundTaskID: nil)
            case .backgrounded(let taskID):
                return ExecSupervisorResult(stdout: "", stderr: "", exitCode: 0, timedOut: false, backgroundTaskID: taskID)
            case .timedOut:
                try await handle.finalizeExec(params: SandboxFinalizeExecParams(status: .failed, exitCode: nil, timedOut: true))
                throw SandboxBackendError.commandFailed("timed out")
            }
        }
        let stdin: Data? = spec.stdinMode == .pipe ? Data() : nil
        let result = try await ShellProcessRunner.runSupervised(
            argv: spec.argv,
            env: spec.env,
            cwd: spec.cwd,
            stdin: stdin,
            timeoutSeconds: timeoutSeconds,
            usePty: spec.usePty,
            inheritHostEnvironment: spec.inheritHostEnvironment
        )
        let status: SandboxExecStatus = result.exitCode == 0 ? .completed : .failed
        try await handle.finalizeExec(params: SandboxFinalizeExecParams(status: status, exitCode: result.exitCode, timedOut: false))
        return ExecSupervisorResult(
            stdout: String(decoding: result.stdout, as: UTF8.self),
            stderr: String(decoding: result.stderr, as: UTF8.self),
            exitCode: result.exitCode,
            timedOut: false,
            backgroundTaskID: nil
        )
    }

    public static func runBackground(
        sessionSlug: String,
        handle: any SandboxBackendHandle,
        params: SandboxBuildExecSpecParams,
        registry: BashProcessRegistry = .shared
    ) async throws -> ExecSupervisorResult {
        let spec = try await handle.buildExecSpec(params: params)
        let taskID = try await registry.register(
            sessionSlug: sessionSlug,
            argv: spec.argv,
            env: spec.env,
            cwd: spec.cwd,
            usePty: spec.usePty,
            inheritHostEnvironment: spec.inheritHostEnvironment
        )
        return ExecSupervisorResult(stdout: "", stderr: "", exitCode: 0, timedOut: false, backgroundTaskID: taskID)
    }
}
