import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Remote sandbox env overlay")
struct RemoteSandboxEnvOverlayTests {
    @Test("Docker execFlags emits sorted -e pairs")
    func dockerExecFlags() throws {
        let flags = try DockerSandboxEnvPolicy.execFlags(env: [
            "ZEBRA": "last",
            "ALPHA": "first",
            "MID": "a=b",
        ])
        #expect(flags == ["-e", "ALPHA=first", "-e", "MID=a=b", "-e", "ZEBRA=last"])
    }

    @Test("Docker execArgv injects -e before -w for buildExecSpec path")
    func dockerExecArgvBuildExecSpecPath() throws {
        let argv = try DockerSandboxShellCommand.execArgv(
            containerName: "c",
            workdir: "/w",
            command: "printenv SAH_TEST_OVERLAY",
            env: ["SAH_TEST_OVERLAY": "visible"],
            usePty: true
        )
        let wIdx = try #require(argv.firstIndex(of: "-w"))
        let eIdx = try #require(argv.firstIndex(of: "-e"))
        #expect(eIdx < wIdx)
        #expect(argv.contains("-it"))
        #expect(argv.contains("SAH_TEST_OVERLAY=visible"))
        #expect(!argv.contains("-i") || argv.contains("-it"))
    }

    @Test("Docker execArgv injects -i and -e for runShellCommand path")
    func dockerExecArgvRunShellCommandPath() throws {
        let params = SandboxBackendCommandParams(
            script: #"cat "$1""#,
            args: ["foo.txt"],
            env: ["SAH_TEST_OVERLAY": "visible"]
        )
        let argv = try DockerSandboxShellCommand.argv(containerName: "c", workdir: "/w", params: params)
        #expect(argv.contains("-i"))
        #expect(!argv.contains("-it"))
        #expect(argv.contains("-e"))
        #expect(argv.contains("SAH_TEST_OVERLAY=visible"))
        #expect(argv.suffix(2) == ["--", "foo.txt"])
    }

    @Test("SSH wrapWithEnv prepends exports")
    func sshWrapWithEnv() throws {
        let wrapped = try SSHRemoteShellCommand.wrapWithEnv(
            ["SAH_TEST_OVERLAY": "visible", "OTHER": "x"],
            remoteCommand: "cd /remote && echo hi"
        )
        #expect(wrapped.hasPrefix("export OTHER='x'; export SAH_TEST_OVERLAY='visible'; "))
        #expect(wrapped.hasSuffix("cd /remote && echo hi"))
    }

    @Test("SSH wrapWithEnv is no-op when env empty")
    func sshWrapWithEnvEmpty() throws {
        let command = "cd /remote && echo hi"
        #expect(try SSHRemoteShellCommand.wrapWithEnv([:], remoteCommand: command) == command)
    }

    @Test("SSH wrapWithEnv quotes values with single quotes")
    func sshWrapWithEnvQuoting() throws {
        let wrapped = try SSHRemoteShellCommand.wrapWithEnv(
            ["SAH_TEST": "foo'bar"],
            remoteCommand: "echo hi"
        )
        #expect(wrapped.hasPrefix("export SAH_TEST='foo'\\''bar'; "))
    }

    @Test("OpenShell execFlags emits sorted --env pairs")
    func openshellExecFlags() throws {
        let flags = try OpenShellSandboxEnvPolicy.execFlags(env: [
            "B": "two",
            "A": "one",
        ])
        #expect(flags == ["--env", "A=one", "--env", "B=two"])
    }

    @Test("OpenShell execFlags rejects OPENSHELL_ prefix")
    func openshellRejectsReservedPrefix() {
        #expect(throws: SandboxBackendError.self) {
            _ = try OpenShellSandboxEnvPolicy.execFlags(env: ["OPENSHELL_GATEWAY": "x"])
        }
    }

    @Test("OpenShell exec argv includes --env before command separator")
    func openshellExecArgv() throws {
        let argv = try OpenShellSandboxArgv.exec(
            cliPath: "/usr/local/bin/openshell",
            sandboxName: "test-sandbox",
            workdir: "/workspace",
            command: "printenv SAH_TEST_OVERLAY",
            usePty: true,
            env: ["SAH_TEST_OVERLAY": "visible"]
        )
        let envIdx = try #require(argv.firstIndex(of: "--env"))
        let sepIdx = try #require(argv.firstIndex(of: "--"))
        #expect(envIdx < sepIdx)
        #expect(argv.contains("SAH_TEST_OVERLAY=visible"))
        #expect(argv.contains("--tty"))
    }

    @Test("SandboxRemoteEnvPolicy rejects invalid env keys")
    func rejectsInvalidEnvKeys() {
        #expect(throws: SandboxBackendError.self) {
            _ = try SandboxRemoteEnvPolicy.sortedPairs(["bad-key": "value"])
        }
    }
}
