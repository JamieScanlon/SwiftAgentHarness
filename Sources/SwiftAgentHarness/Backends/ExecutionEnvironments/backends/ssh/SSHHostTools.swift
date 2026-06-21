import Foundation

enum SSHHostTools {
    static let rsyncCandidates = ["/usr/bin/rsync", "/bin/rsync"]

    static func localRsyncAvailable(fileManager: FileManager = .default) -> Bool {
        rsyncCandidates.contains { fileManager.isExecutableFile(atPath: $0) }
    }

    static func requireLocalRsync(fileManager: FileManager = .default) throws {
        guard localRsyncAvailable(fileManager: fileManager) else {
            throw SandboxBackendError.hostToolMissing(tool: "rsync", location: "gateway")
        }
    }

    static func remoteRsyncAvailable(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        runner: any SSHWorkspaceSyncRunning = DefaultSSHWorkspaceSyncRunner()
    ) async throws -> Bool {
        let result = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "command -v rsync"
        ))
        return result.exitCode == 0
    }

    static func requireRemoteRsync(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        runner: any SSHWorkspaceSyncRunning = DefaultSSHWorkspaceSyncRunner()
    ) async throws {
        guard try await remoteRsyncAvailable(control: control, settings: settings, runner: runner) else {
            throw SandboxBackendError.hostToolMissing(
                tool: "rsync",
                location: SSHSandboxArgv.destination(settings)
            )
        }
    }

    static func mapRsyncFailure(
        _ result: ShellProcessRunner.RunResult,
        settings: SSHSandboxSettings,
        localAlreadyVerified: Bool
    ) -> SandboxBackendError {
        guard looksLikeMissingRsync(result) else {
            return SandboxBackendError.commandFailed(rsyncFailureText(result))
        }
        let location = localAlreadyVerified ? SSHSandboxArgv.destination(settings) : "gateway"
        return SandboxBackendError.hostToolMissing(tool: "rsync", location: location)
    }

    private static func looksLikeMissingRsync(_ result: ShellProcessRunner.RunResult) -> Bool {
        if result.exitCode == 127 { return true }
        let text = rsyncFailureText(result).lowercased()
        return text.contains("command not found") && text.contains("rsync")
    }

    private static func rsyncFailureText(_ result: ShellProcessRunner.RunResult) -> String {
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        if !stderr.isEmpty { return stderr }
        return String(data: result.stdout, encoding: .utf8) ?? "rsync failed"
    }
}
