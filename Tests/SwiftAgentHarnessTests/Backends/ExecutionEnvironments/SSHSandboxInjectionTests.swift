import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SSH sandbox scope key injection")
struct SSHSandboxInjectionTests {
    @Test("remoteRoot path uses sanitized scope key")
    func remoteRootPath() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(
            scope: .session,
            sessionKey: "webhook:delegated:alerts",
            agentID: "a"
        )
        #expect(scopeKey == "session-webhook_delegated_alerts")
        #expect(SSHSandboxRemoteRoot.path(scopeKey: scopeKey) == "/tmp/sah-session-webhook_delegated_alerts")
    }

    @Test("exec remote command shell-quotes remoteRoot")
    func execRemoteCommandQuotesRemoteRoot() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(scope: .agent, sessionKey: "s", agentID: "my-agent")
        let remoteRoot = SSHSandboxRemoteRoot.path(scopeKey: scopeKey)
        let quotedRemoteRoot = SSHRemoteShellCommand.shellQuote(remoteRoot)
        let remoteCommand = "cd \(quotedRemoteRoot) && echo hi"

        #expect(remoteCommand.contains(quotedRemoteRoot))
        #expect(remoteCommand.hasPrefix("cd '\(remoteRoot)' &&"))
    }

    @Test("removeRuntime remote command shell-quotes remoteRoot")
    func removeRuntimeQuotesRemoteRoot() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(
            scope: .session,
            sessionKey: "x; rm -rf / #",
            agentID: "a"
        )
        let remoteRoot = SSHSandboxRemoteRoot.path(scopeKey: scopeKey)
        let quotedRemoteRoot = SSHRemoteShellCommand.shellQuote(remoteRoot)
        let remoteCommand = "rm -rf \(quotedRemoteRoot)"

        #expect(!remoteCommand.contains("; rm -rf /"))
        #expect(remoteCommand == "rm -rf '\(remoteRoot)'")
    }

    @Test("workspace sync remote commands shell-quote remoteRoot")
    func workspaceSyncQuotesRemoteRoot() {
        let remoteRoot = "/tmp/sah-session-test"
        let quotedRemoteRoot = SSHRemoteShellCommand.shellQuote(remoteRoot)

        let mkdirCommand = "mkdir -p \(quotedRemoteRoot)"
        let markerCommand = "test -f \(quotedRemoteRoot)/\(SSHWorkspaceSyncCache.seedMarker)"
        let touchCommand = "touch \(quotedRemoteRoot)/\(SSHWorkspaceSyncCache.seedMarker)"

        #expect(mkdirCommand == "mkdir -p '\(remoteRoot)'")
        #expect(markerCommand == "test -f '\(remoteRoot)'/\(SSHWorkspaceSyncCache.seedMarker)")
        #expect(touchCommand == "touch '\(remoteRoot)'/\(SSHWorkspaceSyncCache.seedMarker)")
    }
}
