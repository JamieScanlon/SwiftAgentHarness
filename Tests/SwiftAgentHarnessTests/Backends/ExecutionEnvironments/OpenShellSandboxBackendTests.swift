import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("OpenShell sandbox backend")
struct OpenShellSandboxBackendTests {
    private let mirrorRoot = "/tmp/sah-test-mirror"
    private let configHash = "deadbeef"

    @Test("create argv includes bind mount and config hash label")
    func createArgvIncludesBindMount() throws {
        let driverJSON = try OpenShellSandboxDriverConfig.bindMountJSON(
            source: mirrorRoot,
            target: "/workspace",
            driver: "docker"
        )
        let argv = OpenShellSandboxArgv.create(
            cliPath: "/usr/local/bin/openshell",
            sandboxName: "sah-test",
            configHash: configHash,
            fromImage: "base",
            driverConfigJSON: driverJSON,
            keepAliveCommand: ["sleep", "infinity"]
        )
        #expect(argv.contains("sandbox"))
        #expect(argv.contains("create"))
        #expect(argv.contains("--name"))
        #expect(argv.contains("sah-test"))
        #expect(argv.contains("--label"))
        #expect(argv.contains("sah.configHash=\(configHash)"))
        #expect(argv.contains("--from"))
        #expect(argv.contains("base"))
        #expect(argv.contains("--driver-config-json"))
        let jsonIdx = try #require(argv.firstIndex(of: "--driver-config-json"))
        let json = argv[jsonIdx + 1]
        #expect(json.contains("sah-test-mirror"))
        #expect(json.contains("/workspace") || json.contains("\\/workspace"))
        #expect(json.contains("\"type\":\"bind\""))
        #expect(argv.suffix(2) == ["sleep", "infinity"])
    }

    @Test("exec argv uses sandbox exec subcommand")
    func execArgvUsesSandboxExecSubcommand() throws {
        let argv = try OpenShellSandboxArgv.exec(
            cliPath: "/usr/local/bin/openshell",
            sandboxName: "test-sandbox",
            workdir: "/workspace",
            command: "npm test",
            usePty: true
        )
        #expect(argv == [
            "/usr/local/bin/openshell",
            "sandbox",
            "exec",
            "-n",
            "test-sandbox",
            "--workdir",
            "/workspace",
            "--tty",
            "--",
            "/bin/bash",
            "-lc",
            "npm test",
        ])
    }

    @Test("describe JSON parsing extracts phase and config hash label")
    func describeJSONParsing() throws {
        let json = """
        {"phase":"Ready","labels":{"sah.configHash":"\(configHash)"}}
        """
        let result = try OpenShellSandboxDescribeResult.parse(data: Data(json.utf8))
        #expect(result.running)
        #expect(result.configHash == configHash)
    }

    @Test("describe JSON parsing supports metadata labels")
    func describeJSONMetadataLabels() throws {
        let json = """
        {"phase":"provisioning","metadata":{"labels":{"sah.configHash":"\(configHash)"}}}
        """
        let result = try OpenShellSandboxDescribeResult.parse(data: Data(json.utf8))
        #expect(!result.running)
        #expect(result.configHash == configHash)
    }

    @Test("config match requires label hash when running")
    func configMatchWhenRunning() {
        #expect(OpenShellSandboxConfigMatch.matches(running: true, labelHash: configHash, currentHash: configHash))
        #expect(!OpenShellSandboxConfigMatch.matches(running: true, labelHash: "other", currentHash: configHash))
        #expect(OpenShellSandboxConfigMatch.matches(running: false, labelHash: nil, currentHash: configHash))
    }

    @Test("finalizeExec syncs mirror on failed exec")
    func finalizeExecSyncsOnFailure() async throws {
        try await WorkspaceMirrorSyncTestIsolation.withExclusiveAccess {
            let host = FileManager.default.temporaryDirectory
                .appendingPathComponent("openshell-host-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: host) }

            final class RecordingRunner: WorkspaceMirrorSyncRunning, @unchecked Sendable {
                private let lock = NSLock()
                private var _calls: [String] = []
                var calls: [String] { lock.withLock { _calls } }
                func run(argv: [String]) async throws -> ShellProcessRunner.RunResult {
                    lock.withLock { _calls.append(argv.joined(separator: " ")) }
                    return ShellProcessRunner.RunResult(stdout: Data(), stderr: Data(), exitCode: 0)
                }
            }
            let runner = RecordingRunner()
            await WorkspaceMirrorSync.shared.setRunnerForTesting(runner)

            let params = CreateSandboxBackendParams(
                sessionKey: "sess",
                scopeKey: "agent-1",
                workspaceDir: host.path,
                agentWorkspaceDir: host.path,
                config: SandboxConfig(
                    mode: .all,
                    scope: .agent,
                    backend: "openshell",
                    sandboxingActive: true,
                    openshell: OpenShellSandboxSettings()
                ),
                memoryDirectory: nil
            )
            let handle = try OpenShellSandboxBackendHandle(params: params)
            try await handle.finalizeExec(
                params: SandboxFinalizeExecParams(status: .failed, exitCode: 1, timedOut: false)
            )
            #expect(runner.calls.count == 1)
            #expect(runner.calls[0].contains("rsync"))
        }
    }

    @Test("openshell config hash changes when workdir changes")
    func openshellConfigHashDiffersOnWorkdirChange() {
        let base = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "openshell",
            sandboxingActive: true,
            openshell: OpenShellSandboxSettings(workdir: "/workspace")
        )
        let modified = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "openshell",
            sandboxingActive: true,
            openshell: OpenShellSandboxSettings(workdir: "/sandbox")
        )
        #expect(SandboxConfigHash.compute(config: base) != SandboxConfigHash.compute(config: modified))
    }

    @Test("openshell config hash differs from docker hash")
    func openshellConfigHashDistinctFromDocker() {
        let openshell = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "openshell",
            sandboxingActive: true,
            openshell: OpenShellSandboxSettings()
        )
        let docker = SandboxConfig(
            mode: .nonMain,
            scope: .agent,
            backend: "docker",
            sandboxingActive: true
        )
        #expect(SandboxConfigHash.compute(config: openshell) != SandboxConfigHash.compute(config: docker))
    }
}
