import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SSH sandbox backend")
struct SSHSandboxBackendTests {
    private let settings = SSHSandboxSettings(host: "example.com", port: 2222, user: "alice", identityFile: "/tmp/id_rsa")
    private let control: SSHControlMaster

    init() {
        control = SSHControlMaster(settings: settings)
    }

    @Test("exec argv has no stray identity flag before host")
    func execArgvNoStrayIdentityFlag() throws {
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "cd /remote && echo hi"
        )
        let host = SSHSandboxArgv.destination(settings)
        let hostIdx = try #require(argv.firstIndex(of: host))
        if hostIdx > 0 {
            #expect(argv[hostIdx - 1] != "-i" || argv[hostIdx - 2] == "/tmp/id_rsa")
        }
        #expect(argv.filter { $0 == "-i" }.count == 1)
        #expect(argv.contains("/tmp/id_rsa"))
    }

    @Test("base args use configured port")
    func baseArgsUseConfiguredPort() {
        #expect(control.baseArgs.contains("-p"))
        #expect(control.baseArgs.contains("2222"))
        #expect(!control.baseArgs.contains("22") || control.baseArgs.contains("2222"))
    }

    @Test("control master socket lives under .ssh not /tmp")
    func controlMasterSocketUnderSSH() {
        #expect(control.socketPath.contains("/.ssh/sah-control-"))
        #expect(control.socketPath.hasSuffix(".sock"))
        #expect(!control.socketPath.contains("/tmp/sah-ssh-"))
    }

    @Test("base args enforce headless-safe host key policy")
    func baseArgsHostKeyPolicy() {
        #expect(control.baseArgs.contains("StrictHostKeyChecking=accept-new"))
        #expect(control.baseArgs.contains(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        let knownHostsOption = control.baseArgs.first(where: { $0.hasPrefix("UserKnownHostsFile=") })
        #expect(knownHostsOption?.contains("/.ssh/sah-known-hosts") == true)
    }

    @Test("known hosts file shares .ssh directory with control socket")
    func knownHostsSharesSSHDirectory() {
        let socketDir = URL(fileURLWithPath: control.socketPath).deletingLastPathComponent().path
        let knownHostsDir = URL(fileURLWithPath: control.knownHostsPath).deletingLastPathComponent().path
        #expect(socketDir == knownHostsDir)
        #expect(control.knownHostsPath.hasSuffix("/sah-known-hosts"))
    }

    @Test("exec argv includes host key policy")
    func execArgvIncludesHostKeyPolicy() {
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "cd /remote && echo hi"
        )
        #expect(argv.contains("StrictHostKeyChecking=accept-new"))
        #expect(argv.contains(where: { $0.hasPrefix("UserKnownHostsFile=") }))
    }

    @Test("rsync transport includes host key policy")
    func rsyncTransportIncludesHostKeyPolicy() {
        let transport = SSHSandboxArgv.rsyncTransport(control: control, settings: settings)
        #expect(transport.contains("StrictHostKeyChecking=accept-new"))
        #expect(transport.contains("UserKnownHostsFile="))
        #expect(transport.contains("sah-known-hosts"))
    }

    @Test("connectivity probe uses shared host key policy and identity")
    func connectivityProbeArgv() throws {
        let argv = SSHSandboxArgv.connectivityProbe(control: control, settings: settings)
        #expect(argv.contains("StrictHostKeyChecking=accept-new"))
        #expect(argv.contains("BatchMode=yes"))
        #expect(argv.contains("ConnectTimeout=5"))
        #expect(argv.contains("/tmp/id_rsa"))
        let host = SSHSandboxArgv.destination(settings)
        let hostIdx = try #require(argv.firstIndex(of: host))
        let batchIdx = try #require(argv.firstIndex(of: "BatchMode=yes"))
        #expect(batchIdx < hostIdx)
    }

    @Test("-tt precedes host when usePty")
    func ttPrecedesHostWhenUsePty() throws {
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "cd /remote && echo hi",
            usePty: true
        )
        #expect(argv.contains("-tt"))
        let ttIdx = try #require(argv.firstIndex(of: "-tt"))
        let hostIdx = try #require(argv.firstIndex(of: SSHSandboxArgv.destination(settings)))
        #expect(ttIdx < hostIdx)
    }

    @Test("changedPairs detects mtime change")
    func changedPairsDetectsMtimeChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tracked.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)

        var sync = FileSyncManager()
        sync.track(hostPath: file.path, remotePath: "/remote/tracked.txt")
        #expect(sync.changedPairs().isEmpty)

        try "v2".write(to: file, atomically: true, encoding: .utf8)
        let changed = sync.changedPairs()
        #expect(changed.count == 1)
        #expect(changed[0].hostPath == file.path)
    }

    @Test("trackTree indexes workspace files")
    func trackTreeIndexesWorkspaceFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-tree-\(UUID().uuidString)", isDirectory: true)
        let nested = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rootFile = dir.appendingPathComponent("root.txt")
        let nestedFile = nested.appendingPathComponent("leaf.txt")
        try "root".write(to: rootFile, atomically: true, encoding: .utf8)
        try "leaf".write(to: nestedFile, atomically: true, encoding: .utf8)

        var sync = FileSyncManager()
        sync.trackTree(hostRoot: dir.path, remoteRoot: "/remote")
        #expect(!sync.isEmpty)
        let changed = sync.changedPairs()
        #expect(changed.isEmpty)
    }
}

private final class SSHWorkspaceSyncSpy: SSHWorkspaceSyncRunning, @unchecked Sendable {
    var runs: [[String]] = []
    var markerPresent = false

    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        runs.append(argv)
        if let last = argv.last, last == "command -v rsync" {
            return ShellProcessRunner.RunResult(stdout: Data("/usr/bin/rsync\n".utf8), stderr: Data(), exitCode: 0)
        }
        if let last = argv.last, last.contains("umask 077"), last.contains("mkdir -p \"$target\"") {
            return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        if let last = argv.last, last.contains("test -f"), last.contains(SSHWorkspaceSyncCache.seedMarker) {
            return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: markerPresent ? 0 : 1)
        }
        if argv.first == "rsync", argv.contains("--delete") {
            markerPresent = true
        }
        if let last = argv.last, last.contains("touch"), last.contains(SSHWorkspaceSyncCache.seedMarker) {
            markerPresent = true
        }
        return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}

@Suite("SSH workspace sync cache")
struct SSHWorkspaceSyncCacheTests {
    private let settings = SSHSandboxSettings(host: "example.com", port: 22, user: "alice")
    private let control: SSHControlMaster

    init() {
        control = SSHControlMaster(settings: settings)
    }

    private func makeHostWorkspace() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "seed".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        return dir.path
    }

    @Test("full seed runs once when marker absent")
    func fullSeedRunsOnceWhenMarkerAbsent() async throws {
        let host = try makeHostWorkspace()
        defer { try? FileManager.default.removeItem(atPath: host) }
        let spy = SSHWorkspaceSyncSpy()
        let cache = SSHWorkspaceSyncCache()
        await cache.setRunnerForTesting(spy)
        let scopeKey = "test-\(UUID().uuidString)"

        try await cache.prepare(
            control: control,
            settings: settings,
            hostWorkspace: host,
            scopeKey: scopeKey
        )

        #expect(spy.runs.contains { $0.first == "rsync" && $0.contains("--delete") })
        let rsyncRun = try #require(spy.runs.first { $0.first == "rsync" && $0.contains("--delete") })
        #expect(rsyncRun.contains("alice@example.com:.sah/workspaces/\(scopeKey)/"))
        let rsyncCount = spy.runs.filter { $0.first == "rsync" && $0.contains("--delete") }.count
        #expect(rsyncCount == 1)

        try await cache.prepare(
            control: control,
            settings: settings,
            hostWorkspace: host,
            scopeKey: scopeKey
        )
        let rsyncCountAfter = spy.runs.filter { $0.first == "rsync" && $0.contains("--delete") }.count
        #expect(rsyncCountAfter == 1)
    }

    @Test("incremental sync sends only changed files on second prepare")
    func incrementalSyncOnSecondPrepare() async throws {
        let host = try makeHostWorkspace()
        defer { try? FileManager.default.removeItem(atPath: host) }
        let spy = SSHWorkspaceSyncSpy()
        let cache = SSHWorkspaceSyncCache()
        await cache.setRunnerForTesting(spy)
        let scopeKey = "incr-\(UUID().uuidString)"

        try await cache.prepare(
            control: control,
            settings: settings,
            hostWorkspace: host,
            scopeKey: scopeKey
        )

        let file = URL(fileURLWithPath: host).appendingPathComponent("file.txt")
        try "updated".write(to: file, atomically: true, encoding: .utf8)

        try await cache.prepare(
            control: control,
            settings: settings,
            hostWorkspace: host,
            scopeKey: scopeKey
        )

        let incremental = spy.runs.filter { $0.first == "rsync" && !$0.contains("--delete") }
        #expect(!incremental.isEmpty)
    }

    @Test("prepare throws when remote rsync missing")
    func prepareThrowsWhenRemoteRsyncMissing() async throws {
        let host = try makeHostWorkspace()
        defer { try? FileManager.default.removeItem(atPath: host) }
        let spy = RemoteRsyncMissingSyncSpy()
        let cache = SSHWorkspaceSyncCache()
        await cache.setRunnerForTesting(spy)
        let scopeKey = "missing-rsync-\(UUID().uuidString)"

        await #expect(throws: SandboxBackendError.hostToolMissing(tool: "rsync", location: "alice@example.com")) {
            try await cache.prepare(
                control: control,
                settings: settings,
                hostWorkspace: host,
                scopeKey: scopeKey
            )
        }
    }

    @Test("prepare throws when secure workspace setup fails")
    func prepareThrowsWhenSecureSetupFails() async throws {
        let host = try makeHostWorkspace()
        defer { try? FileManager.default.removeItem(atPath: host) }
        let spy = SecurePrepareFailureSyncSpy()
        let cache = SSHWorkspaceSyncCache()
        await cache.setRunnerForTesting(spy)

        await #expect(throws: SandboxBackendError.self) {
            try await cache.prepare(
                control: control,
                settings: settings,
                hostWorkspace: host,
                scopeKey: "squatted"
            )
        }
    }
}

private final class SecurePrepareFailureSyncSpy: SSHWorkspaceSyncRunning, @unchecked Sendable {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        if let last = argv.last, last.contains("umask 077") {
            return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 1)
        }
        return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}

private final class RemoteRsyncMissingSyncSpy: SSHWorkspaceSyncRunning, @unchecked Sendable {
    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        if argv.last == "command -v rsync" {
            return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 1)
        }
        return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
