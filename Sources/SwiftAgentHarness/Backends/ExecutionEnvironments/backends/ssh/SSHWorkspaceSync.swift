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
        remoteRoot: String
    ) async throws {
        try SSHHostTools.requireLocalRsync()

        let quotedRemoteRoot = SSHRemoteShellCommand.shellQuote(remoteRoot)

        _ = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "mkdir -p \(quotedRemoteRoot)"
        ))

        var entry = entries[remoteRoot] ?? Entry(
            seeded: false,
            fileSync: FileSyncManager(),
            hostWorkspace: hostWorkspace,
            remoteRsyncVerified: false
        )
        entry.hostWorkspace = hostWorkspace

        let markerCheck = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "test -f \(quotedRemoteRoot)/\(Self.seedMarker)"
        ))
        let remoteSeeded = markerCheck.exitCode == 0

        try await ensureRemoteRsync(control: control, settings: settings, entry: &entry)

        if !remoteSeeded {
            try await fullSeed(control: control, settings: settings, hostWorkspace: hostWorkspace, remoteRoot: remoteRoot, entry: &entry)
        } else {
            entry.seeded = true
            if entry.fileSync.isEmpty {
                entry.fileSync.trackTree(hostRoot: hostWorkspace, remoteRoot: remoteRoot)
            } else {
                try await incrementalSync(control: control, settings: settings, entry: &entry)
            }
        }

        entries[remoteRoot] = entry
    }

    func remove(remoteRoot: String) {
        entries.removeValue(forKey: remoteRoot)
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
        remoteRoot: String,
        entry: inout Entry
    ) async throws {
        let transport = SSHSandboxArgv.rsyncTransport(control: control, settings: settings)
        let hostSource = hostWorkspace.hasSuffix("/") ? hostWorkspace : hostWorkspace + "/"
        try await runRsync(argv: [
            "rsync", "-az", "--delete", "-e", transport, hostSource,
            "\(SSHSandboxArgv.destination(settings)):\(remoteRoot)/",
        ], settings: settings)
        _ = try await runner.run(argv: SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "touch \(SSHRemoteShellCommand.shellQuote(remoteRoot))/\(Self.seedMarker)"
        ))
        entry.fileSync.trackTree(hostRoot: hostWorkspace, remoteRoot: remoteRoot)
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
