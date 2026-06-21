import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SSH host tools")
struct SSHHostToolsTests {
    private let settings = SSHSandboxSettings(host: "example.com", port: 22, user: "alice")
    private let control: SSHControlMaster

    init() {
        control = SSHControlMaster(settings: settings)
    }

    @Test("local rsync available when executable exists on host")
    func localRsyncAvailableOnHost() {
        let available = SSHHostTools.localRsyncAvailable()
        let hasCandidate = SSHHostTools.rsyncCandidates.contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        #expect(available == hasCandidate)
    }

    @Test("requireLocalRsync throws when rsync missing on gateway")
    func requireLocalRsyncMissing() {
        let fileManager = NoRsyncFileManager()
        #expect(throws: SandboxBackendError.hostToolMissing(tool: "rsync", location: "gateway")) {
            try SSHHostTools.requireLocalRsync(fileManager: fileManager)
        }
    }

    @Test("remote probe uses command -v rsync")
    func remoteProbeArgv() async throws {
        let spy = RemoteRsyncProbeSpy(present: true)
        let available = try await SSHHostTools.remoteRsyncAvailable(
            control: control,
            settings: settings,
            runner: spy
        )
        #expect(available)
        #expect(spy.runs.count == 1)
        #expect(spy.runs[0].last == "command -v rsync")
    }

    @Test("requireRemoteRsync throws when remote rsync missing")
    func requireRemoteRsyncMissing() async {
        let spy = RemoteRsyncProbeSpy(present: false)
        await #expect(throws: SandboxBackendError.hostToolMissing(tool: "rsync", location: "alice@example.com")) {
            try await SSHHostTools.requireRemoteRsync(control: control, settings: settings, runner: spy)
        }
    }

    @Test("mapRsyncFailure maps command not found to hostToolMissing")
    func mapRsyncFailureCommandNotFound() {
        let result = ShellProcessRunner.RunResult(
            stdout: Data(),
            stderr: Data("bash: rsync: command not found\n".utf8),
            exitCode: 127
        )
        let error = SSHHostTools.mapRsyncFailure(result, settings: settings, localAlreadyVerified: true)
        #expect(error == .hostToolMissing(tool: "rsync", location: "alice@example.com"))
    }

    @Test("describeRuntime fails when remote rsync missing")
    func describeRuntimeMissingRemoteRsync() async {
        let spy = RemoteRsyncProbeSpy(present: false)
        let manager = SSHSandboxBackendManager(syncRunner: spy)
        let config = SandboxConfig(
            mode: .all,
            scope: .agent,
            backend: "ssh",
            sandboxingActive: true,
            ssh: settings
        )
        let params = SandboxBackendDescribeRuntimeParams(
            sessionKey: "session",
            scopeKey: "agent:default",
            config: config
        )
        await #expect(throws: SandboxBackendError.hostToolMissing(tool: "rsync", location: "alice@example.com")) {
            try await manager.describeRuntime(params: params)
        }
    }
}

private final class NoRsyncFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool {
        guard !SSHHostTools.rsyncCandidates.contains(path) else { return false }
        return super.isExecutableFile(atPath: path)
    }
}

private final class RemoteRsyncProbeSpy: SSHWorkspaceSyncRunning, @unchecked Sendable {
    var runs: [[String]] = []
    let present: Bool

    init(present: Bool) {
        self.present = present
    }

    func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
        runs.append(argv)
        if argv.last == "command -v rsync" {
            return ShellProcessRunner.RunResult(
                stdout: present ? Data("/usr/bin/rsync\n".utf8) : Data(),
                stderr: Data(),
                exitCode: present ? 0 : 1
            )
        }
        return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}
