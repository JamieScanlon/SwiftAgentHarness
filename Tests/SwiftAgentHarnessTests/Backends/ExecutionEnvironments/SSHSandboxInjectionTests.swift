import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("SSH sandbox scope key injection")
struct SSHSandboxInjectionTests {
    @Test("remoteRoot path uses sanitized scope key under home")
    func remoteRootPath() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(
            scope: .session,
            sessionKey: "webhook:delegated:alerts",
            agentID: "a"
        )
        #expect(scopeKey == "session-webhook_delegated_alerts")
        #expect(SSHSandboxRemoteRoot.runtimeId(scopeKey: scopeKey) == "~/.sah/workspaces/session-webhook_delegated_alerts")
    }

    @Test("exec remote command uses expandable home shell path")
    func execRemoteCommandUsesHomeShellPath() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(scope: .agent, sessionKey: "s", agentID: "my-agent")
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        let remoteCommand = "cd \(shellPath) && echo hi"

        #expect(remoteCommand.contains("$HOME/.sah/workspaces/"))
        #expect(remoteCommand.hasPrefix("cd \"$HOME/.sah/workspaces/agent-my-agent\" &&"))
    }

    @Test("removeRuntime remote command removes home path and legacy tmp path")
    func removeRuntimeQuotesRemoteRoot() {
        let scopeKey = SandboxConfigResolver.resolveScopeKey(
            scope: .session,
            sessionKey: "x; rm -rf / #",
            agentID: "a"
        )
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)
        let legacyQuoted = SSHRemoteShellCommand.shellQuote(SSHSandboxRemoteRoot.legacyPath(scopeKey: scopeKey))
        let remoteCommand = "rm -rf \(shellPath) \(legacyQuoted)"

        #expect(!remoteCommand.contains("; rm -rf /"))
        #expect(remoteCommand.contains(shellPath))
        #expect(remoteCommand.contains(legacyQuoted))
    }

    @Test("workspace sync remote commands use home shell path")
    func workspaceSyncUsesHomeShellPath() {
        let scopeKey = "session-test"
        let shellPath = SSHSandboxRemoteRoot.shellPath(scopeKey: scopeKey)

        let prepareCommand = SSHSandboxRemoteRoot.securePrepareCommand(scopeKey: scopeKey)
        let markerCommand = "test -f \(shellPath)/\(SSHWorkspaceSyncCache.seedMarker)"
        let touchCommand = "touch \(shellPath)/\(SSHWorkspaceSyncCache.seedMarker)"

        #expect(prepareCommand.contains("umask 077"))
        #expect(prepareCommand.contains("[ -L \"$target\" ]"))
        #expect(markerCommand == "test -f \"$HOME/.sah/workspaces/session-test\"/\(SSHWorkspaceSyncCache.seedMarker)")
        #expect(touchCommand == "touch \"$HOME/.sah/workspaces/session-test\"/\(SSHWorkspaceSyncCache.seedMarker)")
    }

    @Test("securePrepareCommand rejects symlink squat targets")
    func securePrepareRejectsSymlinkSquat() {
        let command = SSHSandboxRemoteRoot.securePrepareCommand(scopeKey: "agent-a")
        #expect(command.contains("if [ -e \"$target\" ] && { [ -L \"$target\" ] || [ ! -d \"$target\" ]; }; then exit 1; fi"))
    }

    @Test("rsync destination uses home-relative path")
    func rsyncDestinationUsesHomeRelativePath() {
        let scopeKey = "agent-a"
        #expect(SSHSandboxRemoteRoot.rsyncRelativePath(scopeKey: scopeKey) == ".sah/workspaces/agent-a/")
    }
}
