import Foundation
import Testing
@testable import SwiftAgentHarness

#if os(macOS) || os(Linux)
@Suite("ShellProcessRunner concurrent drain")
struct ShellProcessRunnerDrainTests {
    @Test("drains stdout larger than the pipe buffer without hanging")
    func largeStdout() async throws {
        let byteCount = 4 * 1024 * 1024
        let result = try await ShellProcessRunner.run(
            argv: ["/bin/bash", "-c", "head -c \(byteCount) /dev/zero"],
            timeoutSeconds: 30
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == byteCount)
    }

    @Test("drains stderr larger than the pipe buffer without hanging")
    func largeStderr() async throws {
        let byteCount = 4 * 1024 * 1024
        let result = try await ShellProcessRunner.run(
            argv: ["/bin/bash", "-c", "head -c \(byteCount) /dev/zero 1>&2"],
            timeoutSeconds: 30
        )
        #expect(result.exitCode == 0)
        #expect(result.stderr.count == byteCount)
    }

    @Test("small output returns correct stdout, stderr, and exit code")
    func smallOutput() async throws {
        let result = try await ShellProcessRunner.run(
            argv: ["/bin/bash", "-c", "echo out; echo err 1>&2; exit 3"],
            timeoutSeconds: 30
        )
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
    }

    @Test("timeout throws commandFailed without hanging")
    func timeout() async {
        do {
            _ = try await ShellProcessRunner.run(
                argv: ["/bin/bash", "-c", "sleep 30"],
                timeoutSeconds: 0.2
            )
            Issue.record("expected timeout error")
        } catch SandboxBackendError.commandFailed(let message) {
            #expect(message == "timed out")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
#endif
