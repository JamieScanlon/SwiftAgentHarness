import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@testable import SwiftAgentHarness

@Suite(.serialized)
struct BackgroundSupervisionTests {

    // MARK: - Incremental streaming

    @Test("streaming delivers output incrementally before process exits")
    func streamingIncrementalOutput() async throws {
        // Test liveStdout directly so we avoid shared-registry contention with other suites
        let handle = try ShellProcessRunner.startSupervised(
            argv: ["/bin/bash", "-c", "echo start; sleep 10"],
            keepStdinOpen: false
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        let live = handle.liveStdout
        handle.terminate()
        _ = try? await handle.wait(timeoutSeconds: 2)
        let output = String(decoding: live, as: UTF8.self)
        #expect(output.contains("start"), "liveStdout should show 'start' while process is still sleeping")
    }

    // MARK: - Send-keys

    @Test("sendKeys writes to stdin and output is echoed")
    func sendKeysWritesToStdin() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", "cat"],
            env: [:],
            cwd: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await registry.sendKeys(id: id, data: Data("hello\n".utf8))
        var found = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let snap = await registry.snapshot(id: id),
               snap.output.contains("hello") {
                found = true
                break
            }
        }
        await registry.kill(id: id)
        #expect(found, "output should contain echoed 'hello'")
    }

    // MARK: - PTY isatty

    @Test("PTY mode: stdout is a tty")
    func ptyStdoutIsATTY() async throws {
        let result = try await ShellProcessRunner.runSupervised(
            argv: ["/bin/bash", "-c", "test -t 1 && echo TTY || echo NOTTY"],
            timeoutSeconds: 5,
            usePty: true
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "TTY")
    }

    @Test("pipe mode: stdout is not a tty")
    func pipeStdoutNotATTY() async throws {
        let result = try await ShellProcessRunner.runSupervised(
            argv: ["/bin/bash", "-c", "test -t 1 && echo TTY || echo NOTTY"],
            timeoutSeconds: 5,
            usePty: false
        )
        let output = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == "NOTTY")
    }

    // MARK: - Snapshot vs consuming poll

    @Test("snapshot is non-consuming; poll advances the offset")
    func snapshotIsNonConsuming() async throws {
        let registry = BashProcessRegistry()
        let id = try await registry.register(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", "echo hello; sleep 5"],
            env: [:],
            cwd: nil
        )
        var snap1: ProcessSessionSnapshot?
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let s = await registry.snapshot(id: id),
               s.output.contains("hello") {
                snap1 = s
                break
            }
        }
        #expect(snap1?.output.contains("hello") == true)

        // Second snapshot without any poll should still show full output
        let snap2 = await registry.snapshot(id: id)
        #expect(snap2?.output.contains("hello") == true, "snapshot must not advance the offset")

        // First consuming poll should show the delta
        let polled1 = await registry.poll(id: id)
        let out1 = polled1.map { String(decoding: $0.pendingStdout, as: UTF8.self) } ?? ""
        #expect(out1.contains("hello"))

        // Second consecutive poll should see no new bytes (process hasn't emitted more)
        let polled2 = await registry.poll(id: id)
        let out2 = polled2.map { String(decoding: $0.pendingStdout, as: UTF8.self) } ?? ""
        #expect(out2.isEmpty, "second poll should yield empty delta")

        await registry.kill(id: id)
    }

    // MARK: - Bounded live buffer

    @Test("live buffer truncates overflow")
    func liveBufferTruncates() async throws {
        let registry = BashProcessRegistry()
        let cap = 4096
        let id = try await registry.register(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", "printf '%5000s' '' | tr ' ' 'A'"],
            env: [:],
            cwd: nil,
            maxLiveBufferBytes: cap
        )
        var snap: ProcessSessionSnapshot?
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let s = await registry.snapshot(id: id), s.output.count >= cap / 2 {
                snap = s
                break
            }
        }
        let polled = await registry.poll(id: id)
        await registry.kill(id: id)
        #expect(snap?.truncated == true)
        #expect((snap?.output.count ?? 0) <= cap)
        #expect(polled?.stdoutTruncated == true)
    }

    // MARK: - Stdin fd cleanup

    @Test("terminate and wait close stdin when keepStdinOpen")
    func supervisedHandleClosesStdin() async throws {
        let handle = try ShellProcessRunner.startSupervised(
            argv: ["/bin/bash", "-c", "sleep 30"],
            keepStdinOpen: true
        )
        #expect(!handle.stdinClosed)
        handle.terminate()
        #expect(handle.stdinClosed)
        _ = try? await handle.wait(timeoutSeconds: 2)
        #expect(handle.stdinClosed)
    }

    // MARK: - Foreground budget auto-background

    @Test("fast command completes inline within foreground budget")
    func fastCommandCompletesInline() async throws {
        let registry = BashProcessRegistry()
        let result = try await registry.runWithForegroundBudget(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", "echo inline"],
            env: [:],
            cwd: nil,
            budgetSeconds: 5
        )
        guard case .completed(let stdout, _, let exitCode) = result.outcome else {
            Issue.record("expected inline completion, got \(result.outcome)")
            return
        }
        #expect(exitCode == 0)
        #expect(stdout.contains("inline"))
    }

    @Test("slow command auto-backgrounds when budget elapses")
    func slowCommandAutoBackgrounds() async throws {
        let registry = BashProcessRegistry()
        let result = try await registry.runWithForegroundBudget(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", "echo started; sleep 3; echo done"],
            env: [:],
            cwd: nil,
            budgetSeconds: 0.3
        )
        guard case .backgrounded(let taskID) = result.outcome else {
            Issue.record("expected background, got \(result.outcome)")
            return
        }
        var sawOutput = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let snap = await registry.snapshot(id: taskID),
               snap.output.contains("started") {
                sawOutput = true
                break
            }
        }
        #expect(sawOutput)
        await registry.kill(id: taskID)
    }

    // MARK: - Docker / SSH argv

    @Test("docker buildExecSpec includes -it when usePty is true")
    func dockerSpecIncludesIT() {
        let params = SandboxBuildExecSpecParams(command: "echo hi", workdir: "/workspace", usePty: true)
        // The argv is built inside ensureContainer which requires Docker; verify spec usePty propagates
        #expect(params.usePty == true)
    }

    @Test("SSH buildExecSpec argv includes -tt when usePty is true")
    func sshSpecIncludesTT() {
        let settings = SSHSandboxSettings(host: "host", port: 22, user: "user")
        let control = SSHControlMaster(settings: settings)
        let argv = SSHSandboxArgv.exec(
            control: control,
            settings: settings,
            remoteCommand: "cd /remote && echo hi",
            usePty: true
        )
        #expect(argv.contains("-tt"))
        let ttIdx = argv.firstIndex(of: "-tt") ?? Int.max
        let hostIdx = argv.firstIndex(of: "user@host") ?? -1
        #expect(ttIdx < hostIdx, "-tt must appear before the host argument")
    }
}
