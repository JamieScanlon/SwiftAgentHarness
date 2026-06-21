import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FS bridge shell injection")
struct FsBridgeInjectionTests {
    private let quotePath = "foo'.txt"
    private let quoteSrc = "src'.txt"
    private let quoteDst = "dst'.txt"

    private func assertPathInArgsNotScript(_ params: SandboxBackendCommandParams, paths: [String]) {
        for path in paths {
            #expect(!params.script.contains(path))
        }
        #expect(params.args == paths)
    }

    @Test("readFile passes path as argv positional")
    func readFileWithSingleQuoteInPath() {
        assertPathInArgsNotScript(SandboxFsBridgeShellCommands.readFile(rel: quotePath), paths: [quotePath])
    }

    @Test("writeFile passes path as argv positional")
    func writeFileWithSingleQuoteInPath() {
        assertPathInArgsNotScript(
            SandboxFsBridgeShellCommands.writeFile(rel: quotePath, content: Data("x".utf8)),
            paths: [quotePath]
        )
    }

    @Test("mkdir passes path as argv positional")
    func mkdirWithSingleQuoteInPath() {
        assertPathInArgsNotScript(SandboxFsBridgeShellCommands.mkdir(rel: quotePath), paths: [quotePath])
    }

    @Test("remove passes path as argv positional")
    func removeWithSingleQuoteInPath() {
        assertPathInArgsNotScript(SandboxFsBridgeShellCommands.remove(rel: quotePath), paths: [quotePath])
    }

    @Test("rename passes paths as argv positionals")
    func renameWithSingleQuoteInPath() {
        assertPathInArgsNotScript(
            SandboxFsBridgeShellCommands.rename(relSrc: quoteSrc, relDst: quoteDst),
            paths: [quoteSrc, quoteDst]
        )
    }

    @Test("stat passes path as argv positional")
    func statWithSingleQuoteInPath() {
        assertPathInArgsNotScript(SandboxFsBridgeShellCommands.stat(rel: quotePath), paths: [quotePath])
    }

    @Test("exists passes path as argv positional")
    func existsWithSingleQuoteInPath() {
        assertPathInArgsNotScript(SandboxFsBridgeShellCommands.exists(rel: quotePath), paths: [quotePath])
    }

    @Test("shellQuote escapes single quotes")
    func shellQuote() {
        #expect(SSHRemoteShellCommand.shellQuote("foo") == "'foo'")
        #expect(SSHRemoteShellCommand.shellQuote("foo'bar") == "'foo'\\''bar'")
        #expect(SSHRemoteShellCommand.shellQuote("") == "''")
    }

    @Test("SSH remote script embeds args safely")
    func sshRunShellCommandArgsEmbeddedSafely() {
        let params = SandboxBackendCommandParams(script: #"cat "$1""#, args: [quotePath])
        let remote = SSHRemoteShellCommand.build(params: params)
        #expect(remote.contains("bash -c"))
        #expect(!remote.contains(quotePath))
        #expect(remote.contains(SSHRemoteShellCommand.shellQuote(quotePath)))
    }

    @Test("docker argv forwards args after script")
    func dockerForwardsArgs() {
        let params = SandboxBackendCommandParams(script: #"cat "$1""#, args: [quotePath])
        let argv = DockerSandboxShellCommand.argv(containerName: "c", workdir: "/w", params: params)
        #expect(argv.suffix(2) == ["--", quotePath])
        #expect(!params.script.contains(quotePath))
    }
}
