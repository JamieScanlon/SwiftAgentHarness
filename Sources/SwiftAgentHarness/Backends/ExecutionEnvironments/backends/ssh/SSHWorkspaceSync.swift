import Foundation

protocol SSHWorkspaceSyncRunning: Sendable {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult
}

struct DefaultSSHWorkspaceSyncRunner: SSHWorkspaceSyncRunning {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        try await ShellProcessRunner.run(argv: argv)
    }
}

actor SSHWorkspaceSyncCache {
    static let shared = SSHWorkspaceSyncCache()

    static let seedMarker = ".sah-seeded"

    private struct Entry {
        var seeded: Bool
        var fileSync: FileSyncManager
        var hostWorkspace: String
        var remoteRsyncVerified: Bool
    }

    private var entries: [String: Entry] = [:]
    var runner: any SSHWorkspaceSyncRunning = DefaultSSHWorkspaceSyncRunner()

    func prepare(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        hostWorkspace: String,
        scopeKey: String
    ) async throws {
        try SSHHostTools.requireLocalRsync()

        let prepareResult = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: SSHSandboxRemoteRoot.securePrepareCommand(scopeKey: scopeKey)
        ))
        guard prepareResult.exitCode == 0 else {
            throw SandboxBackendError.commandFailed(
                "remote workspace prepare failed for scope \(scopeKey): workspace path may be squatted or inaccessible"
            )
        }

        var entry = entries[scopeKey] ?? Entry(
            seeded: false,
            fileSync: FileSyncManager(),
            hostWorkspace: hostWorkspace,
            remoteRsyncVerified: false
        )
        entry.hostWorkspace = hostWorkspace

        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        let markerCheck = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "test -f \(shellPath)/\(Self.seedMarker)"
        ))
        let remoteSeeded = markerCheck.exitCode == 0

        try await ensureRemoteRsync(control: control, settings: settings, entry: &entry)

        let remoteSyncRoot = SSHSandboxRemoteRoot.rsyncRelativeRoot(scopeKey: scopeKey)
        if !remoteSeeded {
            try await fullSeed(
                control: control,
                settings: settings,
                hostWorkspace: hostWorkspace,
                scopeKey: scopeKey,
                remoteSyncRoot: remoteSyncRoot,
                entry: &entry
            )
        } else {
            entry.seeded = true
            if entry.fileSync.isEmpty {
                entry.fileSync.trackTree(hostRoot: hostWorkspace, remoteRoot: remoteSyncRoot)
            } else {
                try await incrementalSync(control: control, settings: settings, entry: &entry)
            }
        }

        entries[scopeKey] = entry
    }

    func remove(scopeKey: String) {
        entries.removeValue(forKey: scopeKey)
    }

    func resetForTesting() {
        entries = [:]
        runner = DefaultSSHWorkspaceSyncRunner()
    }

    func setRunnerForTesting(_ runner: any SSHWorkspaceSyncRunning) {
        self.runner = runner
    }

    private func ensureRemoteRsync(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        entry: inout Entry
    ) async throws {
        guard !entry.remoteRsyncVerified else { return }
        try await SSHHostTools.requireRemoteRsync(control: control, settings: settings, runner: runner)
        entry.remoteRsyncVerified = true
    }

    private func runRsync(argv: [String], settings: SSHSandboxSettings) async throws {
        let result = try await runner.run(argv: argv)
        guard result.exitCode == 0 else {
            throw SSHHostTools.mapRsyncFailure(result, settings: settings, localAlreadyVerified: true)
        }
    }

    private func fullSeed(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        hostWorkspace: String,
        scopeKey: String,
        remoteSyncRoot: String,
        entry: inout Entry
    ) async throws {
        let transport = SSHSandboxArgv.rsyncTransport(control: control, settings: settings)
        let hostSource = hostWorkspace.hasSuffix("/") ? hostWorkspace : hostWorkspace + "/"
        try await runRsync(argv: [
            "rsync", "-az", "--delete", "-e", transport, hostSource,
            "\(SSHSandboxArgv.destination(settings)):\(SSHSandboxRemoteRoot.rsyncRelativePath(scopeKey: scopeKey))",
        ], settings: settings)
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        _ = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "touch \(shellPath)/\(Self.seedMarker)"
        ))
        entry.fileSync.trackTree(hostRoot: hostWorkspace, remoteRoot: remoteSyncRoot)
        entry.seeded = true
    }

    private func incrementalSync(
        control: SSHControlMaster,
        settings: SSHSandboxSettings,
        entry: inout Entry
    ) async throws {
        let changed = entry.fileSync.changedPairs()
        guard !changed.isEmpty else { return }
        let transport = SSHSandboxArgv.rsyncTransport(control: control, settings: settings)
        for pair in changed {
            try await runRsync(argv: [
                "rsync", "-az", "-e", transport, pair.hostPath,
                "\(SSHSandboxArgv.destination(settings)):\(pair.remotePath)",
            ], settings: settings)
            entry.fileSync.refresh(hostPath: pair.hostPath, remotePath: pair.remotePath)
        }
    }
}
