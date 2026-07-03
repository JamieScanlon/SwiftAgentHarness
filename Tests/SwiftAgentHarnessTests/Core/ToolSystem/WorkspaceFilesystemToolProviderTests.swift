import EasyJSON
import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentHarness

@Suite("Workspace filesystem tool provider", .serialized)
struct WorkspaceFilesystemToolProviderTests {
    private func makeFixture() throws -> (workspace: URL, memory: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsp-provider-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let memory = base.appendingPathComponent("memory", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "inside".write(to: workspace.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        return (workspace, memory, outside)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func provider(
        workspace: URL,
        memory: URL,
        memoryWriteOnly: Bool = false,
        isMainSession: Bool = false,
        sessionKey: String = "test-session"
    ) -> WorkspaceFilesystemToolProvider {
        let execRuntime = ExecRuntimeService(workspaceRoot: workspace.path)
        let runtimeContext = ExecRuntimeContext(
            sessionKey: sessionKey,
            agentID: "test-agent",
            isMainSession: isMainSession,
            memoryDirectory: memory.path,
            memoryWriteOnly: memoryWriteOnly
        )
        return WorkspaceFilesystemToolProvider(
            workspaceRoot: workspace.path,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            grepForceInProcess: true
        )
    }

    private func elevatedProvider(
        workspace: URL,
        memory: URL,
        perCallElevationModes: [String: ElevatedMode] = [WorkspaceFilesystemToolProvider.bashToolName: .ask],
        elevatedAllowlist: ElevatedAllowlist = .cliDefault,
        senderIdentity: ExecSenderIdentity = .cliDefault,
        headless: Bool = false,
        approvalDelivery: any ExecApprovalDelivering,
        useStubBashRunner: Bool = false,
        stubSandboxExitCode: Int32 = 126
    ) -> WorkspaceFilesystemToolProvider {
        let execRuntime = ExecRuntimeService(
            workspaceRoot: workspace.path,
            approvalDelivery: approvalDelivery
        )
        let runtimeContext = ExecRuntimeContext(
            sessionKey: "test-session",
            agentID: "test-agent",
            isMainSession: false,
            memoryDirectory: memory.path,
            headless: headless
        )
        let bashRunnerFactory: (@Sendable (ExecRuntimeContext) -> any BashShellRunning)? =
            useStubBashRunner
            ? stubBashRunnerFactory(
                execRuntime: execRuntime,
                sandboxExitCode: stubSandboxExitCode
            )
            : nil
        return WorkspaceFilesystemToolProvider(
            workspaceRoot: workspace.path,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            perCallElevationModes: perCallElevationModes,
            elevatedAllowlist: elevatedAllowlist,
            resolveSenderIdentity: { senderIdentity },
            bashRunnerFactory: bashRunnerFactory,
            grepForceInProcess: true
        )
    }

    private func stubBashRunnerFactory(
        execRuntime: ExecRuntimeService,
        sandboxExitCode: Int32 = 126
    ) -> @Sendable (ExecRuntimeContext) -> any BashShellRunning {
        { context in
            StubBashRunner(
                execRuntime: execRuntime,
                runtimeContext: context,
                sandboxExitCode: sandboxExitCode
            )
        }
    }

    private func call(_ name: String, args: [String: String], id: String = "call-1") -> ToolCall {
        ToolCall(name: name, arguments: .object(args.mapValues { JSON.string($0) }), id: id)
    }

    private func bashCall(command: String, elevated: Bool?, id: String = "call-1") -> ToolCall {
        var args: [String: JSON] = ["command": .string(command)]
        if let elevated {
            args["elevated"] = .boolean(elevated)
        }
        return ToolCall(name: WorkspaceFilesystemToolProvider.bashToolName, arguments: .object(args), id: id)
    }

    @Test("read_file rejects absolute path outside workspace")
    func readFileRejectsOutside() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "/etc/passwd"]))
        #expect(result.success == false)
    }

    @Test("read_file rejects relative escape")
    func readFileRejectsEscape() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "../outside/secret.txt"]))
        #expect(result.success == false)
    }

    @Test("read_file reads workspace file")
    func readFileReadsWorkspace() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "inside.txt"]))
        #expect(result.success == true)
        #expect(result.content == "inside")
    }

    @Test("write_file rejects symlink escape")
    func writeFileRejectsSymlinkEscape() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let link = fixture.workspace.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.outside.appendingPathComponent("secret.txt")
        )
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.writeFileToolName, args: [
                "file_path": link.path,
                "content": "pwned",
            ]))
        #expect(result.success == false)
    }

    @Test("grep rejects path traversal")
    func grepRejectsTraversal() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: [
                "pattern": "secret",
                "path": "../../outside",
            ]))
        #expect(result.success == false)
    }

    @Test("glob returns deterministic sorted order")
    func globDeterministicOrder() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "b".write(to: fixture.workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: fixture.workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: fixture.workspace.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.globToolName, args: ["pattern": "*"]))
        #expect(result.success == true)
        #expect(result.content == "a.txt\nb.txt\nc.txt\ninside.txt")
    }

    @Test("glob supports globstar patterns")
    func globStarPattern() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let src = fixture.workspace.appendingPathComponent("src", isDirectory: true)
        let nested = src.appendingPathComponent("nested", isDirectory: true)
        let lib = fixture.workspace.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try "foo".write(to: src.appendingPathComponent("foo.ts"), atomically: true, encoding: .utf8)
        try "bar".write(to: nested.appendingPathComponent("bar.ts"), atomically: true, encoding: .utf8)
        try "libfoo".write(to: lib.appendingPathComponent("foo.ts"), atomically: true, encoding: .utf8)
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.globToolName, args: ["pattern": "src/**/*.ts"]))
        #expect(result.success == true)
        #expect(result.content == "src/foo.ts\nsrc/nested/bar.ts")
    }

    @Test("glob caps after sort")
    func globCapAfterSort() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        for index in 0..<205 {
            let name = String(format: "file_%03d.txt", index)
            try "x".write(to: fixture.workspace.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.globToolName, args: ["pattern": "file_*.txt"]))
        #expect(result.success == true)
        let lines = result.content.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 200)
        #expect(lines.first == "file_000.txt")
        #expect(lines.last == "file_199.txt")
    }

    @Test("grep returns deterministic matching lines")
    func grepDeterministicHits() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "needle".write(to: fixture.workspace.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try "needle".write(to: fixture.workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "needle"]))
        #expect(result.success == true)
        let hits = result.content.split(separator: "\n").map(String.init)
        #expect(hits.count == 2)
        #expect(hits[0].hasSuffix("/a.txt:1:needle"))
        #expect(hits[1].hasSuffix("/z.txt:1:needle"))
    }

    @Test("grep applies regex semantics on lines")
    func grepRegexLineSemantics() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "class Foo\nstruct Bar".write(
            to: fixture.workspace.appendingPathComponent("types.swift"),
            atomically: true,
            encoding: .utf8
        )
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "^class"]))
        #expect(result.success == true)
        #expect(result.content.contains("types.swift:1:class Foo"))
        #expect(!result.content.contains("struct Bar"))
    }

    @Test("grep finds non-swift files")
    func grepFindsNonSwiftFiles() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try #"{"key":"value"}"#.write(
            to: fixture.workspace.appendingPathComponent("data.json"),
            atomically: true,
            encoding: .utf8
        )
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "\"key\""]))
        #expect(result.success == true)
        #expect(result.content.contains("data.json:1:"))
    }

    @Test("grep rejects invalid regex")
    func grepRejectsInvalidRegex() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "[unclosed"]))
        #expect(result.success == false)
        #expect(result.error?.contains("invalid regex:") == true)
    }

    @Test("grep skips binary files")
    func grepSkipsBinary() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        var data = Data("needle".utf8)
        data.append(0)
        data.append(contentsOf: "more".utf8)
        try data.write(to: fixture.workspace.appendingPathComponent("binary.dat"))
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "needle"]))
        #expect(result.success == true)
        #expect(!result.content.contains("binary.dat"))
    }

    #if os(macOS)
    @Test("sandbox-backed grep returns sorted path:line:content")
    func sandboxGrepReturnsMatchingLines() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "alpha match".write(to: fixture.workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta match".write(to: fixture.workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let result = try await provider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            isMainSession: false
        ).executeTool(call(WorkspaceFilesystemToolProvider.grepToolName, args: ["pattern": "match"]))
        #expect(result.success == true)
        let hits = result.content.split(separator: "\n").map(String.init)
        #expect(hits.count == 2)
        #expect(hits[0].contains("a.txt:1:alpha match"))
        #expect(hits[1].contains("b.txt:1:beta match"))
    }
    #endif

    @Test("bash is tagged mutating in descriptor hints")
    func bashIsMutating() async {
        let provider = provider(
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            memory: URL(fileURLWithPath: "/tmp/mem")
        )
        let hints = provider.descriptorHintsByToolName[WorkspaceFilesystemToolProvider.bashToolName]
        #expect(hints?.effectClass == .mutating)
        #expect(hints?.parallelHint == .serialOnly)
    }

    @Test("bash exposes sandbox adapter policy tag")
    func bashPolicyTag() async {
        let provider = provider(
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            memory: URL(fileURLWithPath: "/tmp/mem")
        )
        let definition = ToolDefinition(
            name: WorkspaceFilesystemToolProvider.bashToolName,
            description: "bash",
            parameters: [],
            type: .function
        )
        let tags = await provider.policyTags(for: definition)
        #expect(tags.map(\.rawValue).contains(WorkspaceFilesystemToolProvider.bashSandboxAdapterTag))
    }

    @Test("bash rejects empty command")
    func bashRejectsEmptyCommand() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory)
            .executeTool(call(WorkspaceFilesystemToolProvider.bashToolName, args: ["command": "   "]))
        #expect(result.success == false)
    }

    #if os(macOS)
    @Test("sandboxed bash blocks reading /etc/passwd")
    func sandboxedBashBlocksPasswd() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            isMainSession: false
        ).executeTool(call(WorkspaceFilesystemToolProvider.bashToolName, args: ["command": "cat /etc/passwd"]))
        #expect(result.success == false)
    }

    @Test("sandboxed bash allows workspace file read")
    func sandboxedBashAllowsWorkspaceRead() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            isMainSession: false
        ).executeTool(call(WorkspaceFilesystemToolProvider.bashToolName, args: ["command": "echo \"$(<inside.txt)\""]))
        #expect(result.success == true)
        #expect(result.content.contains("inside"))
    }
    #endif

    @Test("memoryWriteOnly read_file reads MEMORY.md from memory directory")
    func memoryWriteOnlyReadsMemoryIndex() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "# Index".write(to: fixture.memory.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory, memoryWriteOnly: true)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "MEMORY.md"]))
        #expect(result.success == true)
        #expect(result.content == "# Index")
    }

    @Test("memoryWriteOnly read_file returns notFound for absent memory file")
    func memoryWriteOnlyReadMissingReturnsNotFound() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory, memoryWriteOnly: true)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "note.md"]))
        #expect(result.success == false)
        #expect(result.error?.contains("File not found") == true)
    }

    @Test("memoryWriteOnly read_file rejects absolute path outside memory directory")
    func memoryWriteOnlyRejectsAbsoluteOutsideMemory() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory, memoryWriteOnly: true)
            .executeTool(call(WorkspaceFilesystemToolProvider.readFileToolName, args: ["file_path": "/etc/passwd"]))
        #expect(result.success == false)
    }

    @Test("memoryWriteOnly write_file creates file in memory directory")
    func memoryWriteOnlyWritesMemoryFile() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory, memoryWriteOnly: true)
            .executeTool(call(
                WorkspaceFilesystemToolProvider.writeFileToolName,
                args: ["file_path": "new.md", "content": "durable fact"]
            ))
        #expect(result.success == true)
        let written = try String(contentsOf: fixture.memory.appendingPathComponent("new.md"), encoding: .utf8)
        #expect(written == "durable fact")
    }

    @Test("memoryWriteOnly edit_file updates file in memory directory")
    func memoryWriteOnlyEditsMemoryFile() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        try "before".write(to: fixture.memory.appendingPathComponent("existing.md"), atomically: true, encoding: .utf8)
        let result = try await provider(workspace: fixture.workspace, memory: fixture.memory, memoryWriteOnly: true)
            .executeTool(call(
                WorkspaceFilesystemToolProvider.editFileToolName,
                args: ["file_path": "existing.md", "old_string": "before", "new_string": "after"]
            ))
        #expect(result.success == true)
        let edited = try String(contentsOf: fixture.memory.appendingPathComponent("existing.md"), encoding: .utf8)
        #expect(edited == "after")
    }

    @Test("bash tool definition exposes optional elevated parameter")
    func bashExposesElevatedParameter() async {
        let fixture = try? makeFixture()
        let workspace = fixture?.workspace ?? URL(fileURLWithPath: "/tmp/ws")
        let memory = fixture?.memory ?? URL(fileURLWithPath: "/tmp/mem")
        defer { if let fixture { cleanup(fixture.workspace) } }
        let tools = await provider(workspace: workspace, memory: memory).availableTools()
        let bash = tools.first { $0.name == WorkspaceFilesystemToolProvider.bashToolName }
        let elevatedParam = bash?.parameters.first { $0.name == "elevated" }
        #expect(elevatedParam != nil)
        #expect(elevatedParam?.type == "boolean")
        #expect(elevatedParam?.required == false)
    }

    @Test("bash defaults to sandboxed and does not request approval")
    func bashDefaultsSandboxed() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "echo hi", elevated: nil))
        #expect(await recorder.requestCount == 0)
    }

    @Test("bash with elevated:false stays sandboxed")
    func bashElevatedFalseStaysSandboxed() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "echo hi", elevated: false))
        #expect(await recorder.requestCount == 0)
    }

    @Test("bash with elevated:true requests approval and escapes sandbox")
    func bashElevatedTrueEscapes() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "echo elevated-hi", elevated: true))
        #expect(await recorder.requestCount == 1)
        #expect(result.success == true)
        #expect(result.content.contains("elevated-hi"))
    }

    @Test("bash elevated:true is sandboxed when sender not allowlisted")
    func bashElevatedSenderNotAllowed() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            elevatedAllowlist: ElevatedAllowlist(allowFrom: ["discord": ["user-123"]]),
            senderIdentity: ExecSenderIdentity(surface: "discord", senderID: "intruder"),
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "echo hi", elevated: true))
        #expect(await recorder.requestCount == 0)
    }

    @Test("bash elevated:true stays sandboxed when tool absent from per-call map")
    func bashElevatedNotInPerCallMap() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            perCallElevationModes: [:],
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "echo hi", elevated: true))
        #expect(await recorder.requestCount == 0)
    }

    @Test("sandbox denial escalates to approval and succeeds when approved")
    func sandboxDenialEscalatesToApproval() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "echo elevated-ok", elevated: nil))
        #expect(await recorder.requestCount == 1)
        #expect(result.success == true)
        #expect(result.content.contains("elevated-ok"))
    }

    @Test("sandbox denial returns denial reason when approval denied")
    func sandboxDenialApprovalDenied() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery(result: .denied("User rejected command"))
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "xcodebuild", elevated: nil))
        #expect(await recorder.requestCount == 1)
        #expect(result.success == false)
        #expect(result.error == "User rejected command")
        #expect(result.error?.contains("exit 126") == false)
    }

    @Test("sandbox denial does not escalate when per-call map is empty")
    func sandboxDenialNoEscalationWithoutPerCallMap() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            perCallElevationModes: [:],
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "xcodebuild", elevated: nil))
        #expect(await recorder.requestCount == 0)
        #expect(result.success == false)
        #expect(result.error?.contains("elevation is not available") == true)
    }

    @Test("sandbox denial does not escalate when sender not allowlisted")
    func sandboxDenialNoEscalationSenderNotAllowed() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            elevatedAllowlist: ElevatedAllowlist(allowFrom: ["discord": ["user-123"]]),
            senderIdentity: ExecSenderIdentity(surface: "discord", senderID: "intruder"),
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "xcodebuild", elevated: nil))
        #expect(await recorder.requestCount == 0)
        #expect(result.success == false)
        #expect(result.error?.contains("elevation is not available") == true)
    }

    @Test("sandbox denial still prompts when command is durably granted")
    func sandboxDenialStillPromptsWithDurableGrant() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let store = ExecApprovalStore()
        await store.addDurableApproval(command: "echo")
        let recorder = RecordingExecApprovalDelivery(grantStore: store)
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "echo elevated-ok", elevated: nil))
        #expect(await recorder.requestCount == 1)
        #expect(result.success == true)
        #expect(result.content.contains("elevated-ok"))
    }

    @Test("elevated exec ignores pre-seeded durable name grant")
    func elevatedExecIgnoresPreSeededDurableGrant() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let store = ExecApprovalStore()
        await store.addDurableApproval(command: "git status")
        let recorder = RecordingExecApprovalDelivery(grantStore: store)
        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder
        ).executeTool(bashCall(command: "git status", elevated: true))
        #expect(await recorder.requestCount == 1)
    }

    @Test("durable grant from bash -lc does not pre-approve unrelated bash commands")
    func durableGrantFromBashInterpreterDoesNotBypassShell() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let store = ExecApprovalStore()
        await store.addDurableApproval(command: "bash -lc 'echo elevated-ok'")
        let recorder = RecordingExecApprovalDelivery(grantStore: store)
        let approvedEcho = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "echo elevated-ok", elevated: nil))
        #expect(await recorder.requestCount == 1)
        #expect(approvedEcho.success == true)

        _ = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "bash -lc 'rm -rf /'", elevated: nil))
        #expect(await recorder.requestCount == 2)
    }

    @Test("non-126 sandbox failure does not escalate")
    func non126FailureDoesNotEscalate() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            approvalDelivery: recorder,
            useStubBashRunner: true,
            stubSandboxExitCode: 1
        ).executeTool(bashCall(command: "false", elevated: nil))
        #expect(await recorder.requestCount == 0)
        #expect(result.success == false)
        #expect(result.error?.contains("exit 1") == true)
    }

    @Test("sandbox denial escalation denied in headless mode")
    func sandboxDenialHeadlessDenied() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }
        let recorder = RecordingExecApprovalDelivery()
        let result = try await elevatedProvider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            headless: true,
            approvalDelivery: recorder,
            useStubBashRunner: true
        ).executeTool(bashCall(command: "xcodebuild", elevated: nil))
        #expect(await recorder.requestCount == 0)
        #expect(result.success == false)
        #expect(result.error?.contains("headless mode") == true)
        #expect(result.error?.contains("exit 126") == false)
    }

    private func bashCallBackground(command: String, id: String = "call-1") -> ToolCall {
        ToolCall(
            name: WorkspaceFilesystemToolProvider.bashToolName,
            arguments: .object([
                "command": .string(command),
                "run_in_background": .boolean(true),
            ]),
            id: id
        )
    }

    @Test("process tools reject foreign session task IDs (SEC-009)")
    func processToolsRejectForeignSessionTaskIDs() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.workspace) }

        let providerA = provider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            isMainSession: true,
            sessionKey: "session-a"
        )
        let providerB = provider(
            workspace: fixture.workspace,
            memory: fixture.memory,
            isMainSession: true,
            sessionKey: "session-b"
        )

        let bashResult = try await providerA.executeTool(
            bashCallBackground(command: "echo owner-marker; sleep 10")
        )
        #expect(bashResult.success == true)
        guard bashResult.content.hasPrefix("background task: ") else {
            Issue.record("Expected background task id in bash output")
            return
        }
        let taskID = String(bashResult.content.dropFirst("background task: ".count))

        let foreignPoll = try await providerB.executeTool(call(
            WorkspaceFilesystemToolProvider.processToolName,
            args: ["task_id": taskID]
        ))
        #expect(foreignPoll.success == false)
        #expect(foreignPoll.error == "task not found")

        let foreignKill = try await providerB.executeTool(call(
            WorkspaceFilesystemToolProvider.processToolName,
            args: ["task_id": taskID, "action": "kill"]
        ))
        #expect(foreignKill.success == false)
        #expect(foreignKill.error == "task not found")

        let foreignSendKeys = try await providerB.executeTool(call(
            WorkspaceFilesystemToolProvider.processSendKeysToolName,
            args: ["task_id": taskID, "keys": "pwn"]
        ))
        #expect(foreignSendKeys.success == false)
        #expect(foreignSendKeys.error?.contains("process not found") == true)

        let ownerPoll = try await providerA.executeTool(call(
            WorkspaceFilesystemToolProvider.processToolName,
            args: ["task_id": taskID]
        ))
        #expect(ownerPoll.success == true)
        #expect(ownerPoll.content.contains("owner-marker") || ownerPoll.content.contains("running"))

        _ = try await providerA.executeTool(call(
            WorkspaceFilesystemToolProvider.processToolName,
            args: ["task_id": taskID, "action": "kill"]
        ))
    }
}

private struct StubBashRunner: BashShellRunning {
    let execRuntime: ExecRuntimeService
    let runtimeContext: ExecRuntimeContext
    let sandboxExitCode: Int32

    func runBash(
        command: String,
        runInBackground: Bool,
        usePty: Bool,
        approvalContextLines: [String]
    ) async throws -> ExecSupervisorResult {
        if !runtimeContext.elevated.isActive {
            throw SandboxBackendError.nonZeroExit(sandboxExitCode, "")
        }
        return try await execRuntime.runShell(
            command: command,
            context: runtimeContext,
            runInBackground: runInBackground,
            usePty: usePty,
            approvalContextLines: approvalContextLines
        )
    }
}

private actor RecordingExecApprovalDelivery: ExecApprovalDelivering {
    private(set) var requestCount = 0
    private let result: ExecApprovalDeliveryResult
    private let grantStore: ExecApprovalStore

    init(
        result: ExecApprovalDeliveryResult = .approved,
        grantStore: ExecApprovalStore = ExecApprovalStore()
    ) {
        self.result = result
        self.grantStore = grantStore
    }

    func requestApproval(_ request: ExecApprovalRequest, headless: Bool) async -> ExecApprovalDeliveryResult {
        if headless {
            return .headlessDenied("Approval required for exec in headless mode: \(request.command)")
        }
        if request.allowsDurableBypass,
           await grantStore.isDurableApproved(command: request.command) {
            return .approved
        }
        requestCount += 1
        return result
    }

    func sendFollowup(approvalID: String, approved: Bool) async {}
}
