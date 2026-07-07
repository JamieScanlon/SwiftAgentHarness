import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ElevatedSenderResolver")
struct ElevatedSenderResolverTests {
    @Test("allowlisted discord sender is permitted")
    func allowlistedDiscordSender() {
        let allowlist = ElevatedAllowlist(allowFrom: ["discord": ["user-123"]])
        let identity = ExecSenderIdentity(surface: "discord", senderID: "user-123")
        #expect(ElevatedSenderResolver.isAllowed(identity: identity, allowlist: allowlist))
    }

    @Test("non-allowlisted discord sender is rejected")
    func nonAllowlistedDiscordSender() {
        let allowlist = ElevatedAllowlist(allowFrom: ["discord": ["user-123"]])
        let identity = ExecSenderIdentity(surface: "discord", senderID: "other")
        #expect(!ElevatedSenderResolver.isAllowed(identity: identity, allowlist: allowlist))
    }

    @Test("cli wildcard allows any sender when configured")
    func cliWildcard() {
        let allowlist = ElevatedAllowlist(allowFrom: ["cli": ["*"]])
        #expect(ElevatedSenderResolver.isAllowed(identity: ExecSenderIdentity(surface: "cli", senderID: "anyone"), allowlist: allowlist))
    }

    @Test("empty allowlist defaults to cli wildcard")
    func emptyAllowlistDefaultsCli() {
        #expect(ElevatedSenderResolver.isAllowed(identity: .cliDefault, allowlist: ElevatedAllowlist()))
    }
}

@Suite("ElevatedExecHost", .serialized)
struct ElevatedExecHostTests {
    @Test("on and ask modes require exec approval")
    func onAndAskRequireApproval() {
        #expect(ElevatedExecHost.requiresExecApproval(mode: .on))
        #expect(ElevatedExecHost.requiresExecApproval(mode: .ask))
        #expect(ElevatedExecHost.requiresExecApproval(mode: .full) == false)
        #expect(ElevatedExecHost.requiresExecApproval(mode: .off) == false)
    }

    @Test("full mode rejects when sender is not allowed")
    func fullModeRequiresActiveSender() async {
        let context = ElevatedExecContext(mode: .full, senderAllowed: false)
        await #expect(throws: SandboxBackendError.self) {
            _ = try await ElevatedExecHost.run(
                context: context,
                params: SandboxBuildExecSpecParams(command: "echo hi", workdir: "/tmp"),
                execApprovalGranted: true
            )
        }
    }

    @Test("on mode rejects without exec approval grant")
    func onModeRejectsWithoutApproval() async {
        let context = ElevatedExecContext(mode: .on, senderAllowed: true)
        await #expect(throws: SandboxBackendError.self) {
            _ = try await ElevatedExecHost.run(
                context: context,
                params: SandboxBuildExecSpecParams(command: "echo hi", workdir: "/tmp"),
                execApprovalGranted: false
            )
        }
    }

    @Test("fast elevated command completes inline within foreground budget")
    func fastElevatedCompletesInline() async throws {
        let registry = BashProcessRegistry()
        let context = ElevatedExecContext(mode: .full, senderAllowed: true)
        let result = try await ElevatedExecHost.run(
            context: context,
            params: SandboxBuildExecSpecParams(command: "echo inline", workdir: "/tmp"),
            sessionSlug: "elevated-test",
            budgetSeconds: 5,
            execApprovalGranted: true,
            registry: registry
        )
        #expect(result.backgroundTaskID == nil)
        #expect(result.stdout.contains("inline"))
        #expect(result.exitCode == 0)
    }

    @Test("slow elevated command auto-backgrounds when budget elapses")
    func slowElevatedAutoBackgrounds() async throws {
        let registry = BashProcessRegistry()
        let context = ElevatedExecContext(mode: .full, senderAllowed: true)
        let result = try await ElevatedExecHost.run(
            context: context,
            params: SandboxBuildExecSpecParams(command: "echo started; sleep 3", workdir: "/tmp"),
            sessionSlug: "elevated-test",
            budgetSeconds: 0.3,
            execApprovalGranted: true,
            registry: registry
        )
        guard let taskID = result.backgroundTaskID else {
            Issue.record("expected background task ID")
            return
        }
        var sawOutput = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let snap = await registry.snapshot(id: taskID, sessionSlug: "elevated-test"),
               snap.output.contains("started") {
                sawOutput = true
                break
            }
        }
        #expect(sawOutput)
        await registry.kill(id: taskID, sessionSlug: "elevated-test")
    }
}
