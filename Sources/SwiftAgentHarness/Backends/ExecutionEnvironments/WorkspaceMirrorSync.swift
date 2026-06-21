import Foundation

protocol WorkspaceMirrorSyncRunning: Sendable {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult
}

struct DefaultWorkspaceMirrorSyncRunner: WorkspaceMirrorSyncRunning {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        try await ShellProcessRunner.run(argv: argv)
    }
}

actor WorkspaceMirrorSync {
    private struct Entry {
        var fileSync: FileSyncManager
        var hostRoot: String
        var mirrorRoot: String
    }

    private var entries: [String: Entry] = [:]
    var runner: any WorkspaceMirrorSyncRunning = DefaultWorkspaceMirrorSyncRunner()

    func syncBefore(hostRoot: String, mirrorRoot: String) async throws {
        try SSHHostTools.requireLocalRsync()
        var entry = entries[mirrorRoot] ?? Entry(
            fileSync: FileSyncManager(),
            hostRoot: hostRoot,
            mirrorRoot: mirrorRoot
        )
        entry.hostRoot = hostRoot
        entry.mirrorRoot = mirrorRoot
        try await runRsync(from: hostRoot, to: mirrorRoot, deleteExtraneous: true)
        if entry.fileSync.isEmpty {
            entry.fileSync.trackTree(hostRoot: hostRoot, remoteRoot: mirrorRoot)
        } else {
            try await pushChangedHostFiles(entry: &entry)
        }
        entries[mirrorRoot] = entry
    }

    func syncAfter(hostRoot: String, mirrorRoot: String) async throws {
        try SSHHostTools.requireLocalRsync()
        guard var entry = entries[mirrorRoot] else {
            try await runRsync(from: mirrorRoot, to: hostRoot, deleteExtraneous: false)
            return
        }
        entry.hostRoot = hostRoot
        try await runRsync(from: mirrorRoot, to: hostRoot, deleteExtraneous: false)
        entry.fileSync.trackTree(hostRoot: hostRoot, remoteRoot: mirrorRoot)
        entries[mirrorRoot] = entry
    }

    func remove(mirrorRoot: String) {
        entries.removeValue(forKey: mirrorRoot)
    }

    func resetForTesting() {
        entries = [:]
        runner = DefaultWorkspaceMirrorSyncRunner()
    }

    func setRunnerForTesting(_ runner: any WorkspaceMirrorSyncRunning) {
        self.runner = runner
    }

    private func pushChangedHostFiles(entry: inout Entry) async throws {
        let changed = entry.fileSync.changedPairs()
        guard !changed.isEmpty else { return }
        for pair in changed {
            try await runRsync(from: pair.hostPath, to: pair.remotePath, deleteExtraneous: false)
            entry.fileSync.refresh(hostPath: pair.hostPath, remotePath: pair.remotePath)
        }
    }

    private func runRsync(from source: String, to destination: String, deleteExtraneous: Bool) async throws {
        let sourcePath = source.hasSuffix("/") ? source : source + "/"
        var argv = ["rsync", "-az"]
        if deleteExtraneous { argv.append("--delete") }
        argv.append(sourcePath)
        argv.append(destination.hasSuffix("/") ? destination : destination + "/")
        let result = try await runner.run(argv: argv)
        guard result.exitCode == 0 else {
            throw SandboxBackendError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
    }
}

extension WorkspaceMirrorSync {
    static let shared = WorkspaceMirrorSync()
}
