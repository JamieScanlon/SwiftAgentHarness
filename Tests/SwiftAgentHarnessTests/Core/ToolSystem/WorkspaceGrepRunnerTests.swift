import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Workspace grep runner")
struct WorkspaceGrepRunnerTests {
    @Test("in-process grep skips lines over max line bytes")
    func inProcessSkipsOverlongLines() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("grep-line-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let longLine = String(repeating: "a", count: WorkspaceGrepRunner.maxLineBytes + 1) + "needle"
        try? longLine.write(to: base.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)
        try? "needle".write(to: base.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)

        let execRuntime = ExecRuntimeService(workspaceRoot: base.path)
        let runtimeContext = ExecRuntimeContext(
            sessionKey: "grep-test",
            agentID: "agent",
            isMainSession: true,
            memoryDirectory: nil
        )
        let result = await WorkspaceGrepRunner.run(
            pattern: "needle",
            searchRoot: base.path,
            workspaceRoot: base.path,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            forceInProcess: true
        )
        guard case .success(let output) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(!output.contains("huge.txt"))
        #expect(output.contains("small.txt:1:needle"))
    }

    #if os(macOS)
    @Test("sandbox pipeline treats only benign exit codes as success")
    func sandboxPipelineExitCodes() {
        let noMatch = WorkspaceGrepRunner.sandboxPipelineResult(exitCode: 1, output: "")
        guard case .success = noMatch else {
            Issue.record("Expected success for exit 1")
            return
        }
        let sigpipe = WorkspaceGrepRunner.sandboxPipelineResult(exitCode: 141, output: "a.txt:1:hit\n")
        guard case .success(let output) = sigpipe else {
            Issue.record("Expected success for exit 141")
            return
        }
        #expect(output == "a.txt:1:hit")
        let invalid = WorkspaceGrepRunner.sandboxPipelineResult(exitCode: 2, output: "grep: invalid regex\n")
        guard case .failure(.invalidRegex) = invalid else {
            Issue.record("Expected invalidRegex for exit 2")
            return
        }
        let killed = WorkspaceGrepRunner.sandboxPipelineResult(exitCode: 137, output: "")
        guard case .failure(.executionFailed) = killed else {
            Issue.record("Expected executionFailed for exit 137")
            return
        }
    }
    #endif
}
