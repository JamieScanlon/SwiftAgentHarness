import Foundation
import Testing
@testable import SwiftAgentHarness

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(macOS) || os(Linux)
@Suite("ShellProcessRunner supervised process group")
struct ShellProcessRunnerSupervisedTests {
    private func tempPIDPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-pgid-\(UUID().uuidString).pid").path
    }

    private func readPID(from path: String, timeout: TimeInterval = 3) async -> pid_t? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let raw = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func awaitDead(_ pid: pid_t, timeout: TimeInterval = 3) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return kill(pid, 0) != 0
    }

    private func grandchildScript(pidPath: String) -> String {
        "sleep 30 & echo $! > '\(pidPath)'; sleep 30"
    }

    @Test("timeout kills the whole process group")
    func timeoutKillsGroup() async {
        let pidPath = tempPIDPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        do {
            _ = try await ShellProcessRunner.runSupervised(
                argv: ["/bin/bash", "-c", grandchildScript(pidPath: pidPath)],
                timeoutSeconds: 0.5
            )
            Issue.record("expected timeout error")
        } catch SandboxBackendError.commandFailed(let message) {
            #expect(message == "timed out")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let grandchild = await readPID(from: pidPath)
        #expect(grandchild != nil)
        if let grandchild { #expect(await awaitDead(grandchild)) }
    }

    @Test("task cancellation kills the whole process group")
    func cancellationKillsGroup() async {
        let pidPath = tempPIDPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        let task = Task {
            try await ShellProcessRunner.runSupervised(
                argv: ["/bin/bash", "-c", grandchildScript(pidPath: pidPath)]
            )
        }
        let grandchild = await readPID(from: pidPath)
        #expect(grandchild != nil)
        task.cancel()
        _ = try? await task.value
        if let grandchild { #expect(await awaitDead(grandchild)) }
    }

    @Test("background kill signals the whole process group")
    func backgroundKillSignalsGroup() async throws {
        let pidPath = tempPIDPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        await BashProcessRegistry.shared.resetForTesting()
        let id = try await BashProcessRegistry.shared.register(
            sessionSlug: "s",
            argv: ["/bin/bash", "-c", grandchildScript(pidPath: pidPath)],
            env: [:],
            cwd: nil
        )
        let grandchild = await readPID(from: pidPath)
        #expect(grandchild != nil)
        await BashProcessRegistry.shared.kill(id: id)
        if let grandchild { #expect(await awaitDead(grandchild)) }
        await BashProcessRegistry.shared.resetForTesting()
    }

    @Test("cwd is honored without addchdir")
    func cwdHonored() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await ShellProcessRunner.runSupervised(
            argv: ["/bin/bash", "-c", "pwd"],
            cwd: dir.path,
            timeoutSeconds: 10
        )
        #expect(result.exitCode == 0)
        let pwd = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: pwd).resolvingSymlinksInPath().path == dir.resolvingSymlinksInPath().path)
    }

    @Test("small supervised exec returns correct stdout, stderr, and exit code")
    func smallExec() async throws {
        let result = try await ShellProcessRunner.runSupervised(
            argv: ["/bin/bash", "-c", "echo out; echo err 1>&2; exit 3"],
            timeoutSeconds: 10
        )
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test("inheritHostEnvironment false uses exact env")
    func exactEnvironment() async throws {
        let result = try await ShellProcessRunner.runSupervised(
            argv: ["/usr/bin/printenv", "SAH_ONLY_HERE"],
            env: ["SAH_ONLY_HERE": "yes", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeoutSeconds: 10,
            inheritHostEnvironment: false
        )
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "yes")
        let leaked = try await ShellProcessRunner.runSupervised(
            argv: ["/usr/bin/printenv", "OPENAI_API_KEY"],
            env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeoutSeconds: 10,
            inheritHostEnvironment: false
        )
        #expect(leaked.exitCode == 1)
    }
}
#endif
