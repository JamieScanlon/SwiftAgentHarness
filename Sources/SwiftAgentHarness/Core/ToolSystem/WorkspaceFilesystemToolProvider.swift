import EasyJSON
import Foundation
import Logging
import SwiftAgentKit

public struct WorkspaceFilesystemToolProvider: ToolProvider, ToolDescriptorHinting {
    public static let readFileToolName = "read_file"
    public static let writeFileToolName = "write_file"
    public static let editFileToolName = "edit_file"
    public static let globToolName = "glob"
    public static let grepToolName = "grep"
    public static let bashToolName = "bash"
    public static let processToolName = "process"
    public static let processSendKeysToolName = "process_send_keys"
    public static let bashSandboxAdapterTag = "execution.environment.adapter:tool-env.local.sandbox"

    private let workspaceRoot: String
    private let execRuntime: ExecRuntimeService
    private let runtimeContext: ExecRuntimeContext
    private let perCallElevationModes: [String: ElevatedMode]
    private let elevatedAllowlist: ElevatedAllowlist
    private let resolveSenderIdentity: @Sendable () async -> ExecSenderIdentity
    private let onMemoryWrite: (@Sendable (String) async -> Void)?
    private let logger: Logger?
    private let bashRunnerFactory: @Sendable (ExecRuntimeContext) -> any BashShellRunning
    private let grepForceInProcess: Bool

    public var name: String { "WorkspaceFilesystem" }
    public var descriptorHintsByToolName: [String: ToolDescriptorHints] {
        [
            Self.readFileToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.writeFileToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.editFileToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.globToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.grepToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.bashToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
            Self.processToolName: ToolDescriptorHints(effectClass: .readOnly, parallelHint: .parallelizable),
            Self.processSendKeysToolName: ToolDescriptorHints(effectClass: .mutating, parallelHint: .serialOnly),
        ]
    }

    public init(
        workspaceRoot: String,
        execRuntime: ExecRuntimeService,
        runtimeContext: ExecRuntimeContext,
        perCallElevationModes: [String: ElevatedMode] = [:],
        elevatedAllowlist: ElevatedAllowlist = .cliDefault,
        resolveSenderIdentity: @escaping @Sendable () async -> ExecSenderIdentity = { .cliDefault },
        onMemoryWrite: (@Sendable (String) async -> Void)? = nil,
        logger: Logger? = nil,
        grepForceInProcess: Bool = false
    ) {
        self.init(
            workspaceRoot: workspaceRoot,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            perCallElevationModes: perCallElevationModes,
            elevatedAllowlist: elevatedAllowlist,
            resolveSenderIdentity: resolveSenderIdentity,
            onMemoryWrite: onMemoryWrite,
            logger: logger,
            bashRunnerFactory: nil,
            grepForceInProcess: grepForceInProcess
        )
    }

    init(
        workspaceRoot: String,
        execRuntime: ExecRuntimeService,
        runtimeContext: ExecRuntimeContext,
        perCallElevationModes: [String: ElevatedMode] = [:],
        elevatedAllowlist: ElevatedAllowlist = .cliDefault,
        resolveSenderIdentity: @escaping @Sendable () async -> ExecSenderIdentity = { .cliDefault },
        onMemoryWrite: (@Sendable (String) async -> Void)? = nil,
        logger: Logger? = nil,
        bashRunnerFactory: (@Sendable (ExecRuntimeContext) -> any BashShellRunning)?,
        grepForceInProcess: Bool = false
    ) {
        self.workspaceRoot = FilesystemCanonicalPath.resolve(workspaceRoot)
        self.execRuntime = execRuntime
        self.runtimeContext = runtimeContext
        self.perCallElevationModes = perCallElevationModes
        self.elevatedAllowlist = elevatedAllowlist
        self.resolveSenderIdentity = resolveSenderIdentity
        self.onMemoryWrite = onMemoryWrite
        self.logger = logger
        self.grepForceInProcess = grepForceInProcess
        self.bashRunnerFactory = bashRunnerFactory ?? { context in
            LocalSandboxBashExecutor(execRuntime: execRuntime, runtimeContext: context)
        }
    }

    public func availableTools() async -> [ToolDefinition] {
        [
            ToolDefinition(
                name: Self.readFileToolName,
                description: "Read a file from the workspace.",
                parameters: [
                    .init(name: "file_path", description: "Absolute or workspace-relative path", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.writeFileToolName,
                description: "Write a file in the workspace or memory directory.",
                parameters: [
                    .init(name: "file_path", description: "Target path", type: "string", required: true),
                    .init(name: "content", description: "Full file content", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.editFileToolName,
                description: "Replace old_string with new_string in a file.",
                parameters: [
                    .init(name: "file_path", description: "Target path", type: "string", required: true),
                    .init(name: "old_string", description: "Exact text to replace", type: "string", required: true),
                    .init(name: "new_string", description: "Replacement text", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.globToolName,
                description: "Glob files under workspace root using workspace-relative patterns (*, ?, **).",
                parameters: [
                    .init(name: "pattern", description: "Workspace-relative glob pattern", type: "string", required: true),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.grepToolName,
                description: "Search file contents under workspace root; returns path:line:content for each match.",
                parameters: [
                    .init(name: "pattern", description: "Regular expression", type: "string", required: true),
                    .init(name: "path", description: "Optional subdirectory", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.bashToolName,
                description: "Run a shell command in the workspace sandbox.",
                parameters: [
                    .init(name: "command", description: "Shell command", type: "string", required: true),
                    .init(name: "run_in_background", description: "Run in background", type: "boolean", required: false),
                    .init(name: "use_pty", description: "Allocate a pseudo-terminal (makes isatty/ANSI colour work)", type: "boolean", required: false),
                    .init(name: "elevated", description: "Escape the sandbox for this call (requires approval). Defaults to sandboxed.", type: "boolean", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.processToolName,
                description: "Poll or kill a background process.",
                parameters: [
                    .init(name: "task_id", description: "Background task id", type: "string", required: true),
                    .init(name: "action", description: "poll or kill", type: "string", required: false),
                ],
                type: .function
            ),
            ToolDefinition(
                name: Self.processSendKeysToolName,
                description: "Send stdin to a background process.",
                parameters: [
                    .init(name: "task_id", description: "Background task id", type: "string", required: true),
                    .init(name: "keys", description: "Input to send", type: "string", required: true),
                ],
                type: .function
            ),
        ]
    }

    public func policyTags(for definition: ToolDefinition) async -> [ToolPolicyTag] {
        guard definition.name == Self.bashToolName else { return [] }
        return [ToolPolicyTag(rawValue: Self.bashSandboxAdapterTag)]
    }

    public func parallelSafety(for toolCall: ToolCall) async -> ToolParallelSafety {
        switch toolCall.name {
        case Self.bashToolName, Self.processToolName:
            return ToolCallCapabilityClassifier.parallelSafety(for: toolCall.name, arguments: toolCall.arguments)
        default:
            guard let hints = descriptorHintsByToolName[toolCall.name] else { return .unknown }
            if let parallelSafety = hints.parallelSafety {
                return parallelSafety
            }
            switch hints.parallelHint {
            case .parallelizable:
                return .parallelSafe
            case .serialOnly:
                return .mutating
            case .unknown:
                return .unknown
            }
        }
    }

    public func executeTool(_ toolCall: ToolCall) async throws -> ToolResult {
        switch toolCall.name {
        case Self.readFileToolName:
            return await readFile(toolCall)
        case Self.writeFileToolName:
            return await writeFile(toolCall)
        case Self.editFileToolName:
            return await editFile(toolCall)
        case Self.globToolName:
            return glob(toolCall)
        case Self.grepToolName:
            return await grep(toolCall)
        case Self.bashToolName:
            return await bash(toolCall)
        case Self.processToolName:
            return await process(toolCall)
        case Self.processSendKeysToolName:
            return await processSendKeys(toolCall)
        default:
            return err(toolCall, "Unknown tool")
        }
    }

    private func readFile(_ toolCall: ToolCall) async -> ToolResult {
        do {
            let bridge = try await execRuntime.fsBridge(context: runtimeContext)
            let raw = extractString(from: toolCall.arguments, key: "file_path") ?? ""
            _ = try resolveToolPath(raw: raw, requireExists: true)
            let data = try await bridge.readFile(path: raw)
            let content = String(data: data, encoding: .utf8) ?? ""
            return ok(toolCall, content)
        } catch {
            return err(toolCall, pathErrorMessage(error))
        }
    }

    private func writeFile(_ toolCall: ToolCall) async -> ToolResult {
        do {
            let bridge = try await execRuntime.fsBridge(context: runtimeContext)
            let raw = extractString(from: toolCall.arguments, key: "file_path") ?? ""
            let content = extractString(from: toolCall.arguments, key: "content") ?? ""
            let path = try resolveToolPath(raw: raw, requireExists: false)
            try MemoryContentScanner.validateWriteIfMemoryTarget(
                path: path,
                memoryDirectory: memoryDirectoryURL(),
                content: content
            ).get()
            try await bridge.writeFile(path: raw, content: Data(content.utf8))
            await notifyMemoryWrite(path)
            return ok(toolCall, "Wrote \(path)")
        } catch {
            return err(toolCall, pathErrorMessage(error))
        }
    }

    private func editFile(_ toolCall: ToolCall) async -> ToolResult {
        do {
            let bridge = try await execRuntime.fsBridge(context: runtimeContext)
            let raw = extractString(from: toolCall.arguments, key: "file_path") ?? ""
            let oldString = extractString(from: toolCall.arguments, key: "old_string") ?? ""
            let newString = extractString(from: toolCall.arguments, key: "new_string") ?? ""
            let path = try resolveToolPath(raw: raw, requireExists: true)
            let fileData = try await bridge.readFile(path: raw)
            var content = String(data: fileData, encoding: .utf8) ?? ""
            guard content.contains(oldString) else {
                return err(toolCall, "old_string not found")
            }
            content = content.replacingOccurrences(of: oldString, with: newString)
            try MemoryContentScanner.validateWriteIfMemoryTarget(
                path: path,
                memoryDirectory: memoryDirectoryURL(),
                content: content
            ).get()
            try await bridge.writeFile(path: raw, content: Data(content.utf8))
            await notifyMemoryWrite(path)
            return ok(toolCall, "Edited \(path)")
        } catch {
            return err(toolCall, pathErrorMessage(error))
        }
    }

    private func memoryDirectoryURL() -> URL? {
        runtimeContext.memoryDirectory.map { URL(fileURLWithPath: $0) }
    }

    private func resolveToolPath(raw: String, requireExists: Bool) throws -> String {
        if runtimeContext.memoryWriteOnly, let memoryDirectory = memoryDirectoryURL() {
            return try PathPolicy.resolveMemoryRelativePath(
                raw: raw,
                memoryDirectory: memoryDirectory,
                requireExists: requireExists
            )
        }
        if requireExists {
            return try PathPolicy.resolveReadablePath(
                raw: raw,
                workspaceRoot: workspaceRoot,
                memoryDirectory: memoryDirectoryURL(),
                memoryWriteOnly: false
            )
        }
        return try PathPolicy.resolveWritablePath(
            raw: raw,
            workspaceRoot: workspaceRoot,
            memoryDirectory: memoryDirectoryURL(),
            memoryWriteOnly: false
        )
    }

    private func glob(_ toolCall: ToolCall) -> ToolResult {
        let pattern = extractString(from: toolCall.arguments, key: "pattern") ?? "*"
        let relativePaths = WorkspacePathEnumerator.sortedRegularFileRelativePaths(under: workspaceRoot)
        let matches = relativePaths
            .filter { WorkspaceGlobMatcher.matches(relativePath: $0, pattern: pattern) }
            .sorted()
            .prefix(200)
            .joined(separator: "\n")
        return ok(toolCall, matches)
    }

    private func grep(_ toolCall: ToolCall) async -> ToolResult {
        let pattern = extractString(from: toolCall.arguments, key: "pattern") ?? ""
        let sub: String
        do {
            sub = try PathPolicy.resolveSearchRoot(
                raw: extractString(from: toolCall.arguments, key: "path"),
                workspaceRoot: workspaceRoot,
                memoryDirectory: runtimeContext.memoryDirectory.map { URL(fileURLWithPath: $0) },
                memoryWriteOnly: runtimeContext.memoryWriteOnly
            )
        } catch {
            return err(toolCall, pathErrorMessage(error))
        }
        switch await WorkspaceGrepRunner.run(
            pattern: pattern,
            searchRoot: sub,
            workspaceRoot: workspaceRoot,
            execRuntime: execRuntime,
            runtimeContext: runtimeContext,
            forceInProcess: grepForceInProcess
        ) {
        case .success(let output):
            return ok(toolCall, output)
        case .failure(.invalidRegex(let reason)):
            return err(toolCall, "invalid regex: \(reason)")
        case .failure(.timedOut):
            return err(toolCall, "grep timed out after \(Int(WorkspaceGrepRunner.maxWallClockSeconds)) seconds")
        case .failure(.executionFailed(let reason)):
            return err(toolCall, "grep failed: \(reason)")
        }
    }

    private func bashRunner(for context: ExecRuntimeContext) -> any BashShellRunning {
        bashRunnerFactory(context)
    }

    private func bashExecutor(for context: ExecRuntimeContext) -> LocalSandboxBashExecutor {
        LocalSandboxBashExecutor(execRuntime: execRuntime, runtimeContext: context)
    }

    private func elevatedRuntimeContext(toolName: String, elevated: Bool) async -> ExecRuntimeContext {
        guard elevated, let mode = perCallElevationModes[toolName] else { return runtimeContext }
        let identity = await resolveSenderIdentity()
        let senderAllowed = ElevatedSenderResolver.isAllowed(identity: identity, allowlist: elevatedAllowlist)
        return ExecRuntimeContext(
            sessionKey: runtimeContext.sessionKey,
            agentID: runtimeContext.agentID,
            isMainSession: runtimeContext.isMainSession,
            memoryDirectory: runtimeContext.memoryDirectory,
            memoryWriteOnly: runtimeContext.memoryWriteOnly,
            senderIdentity: identity,
            elevated: ElevatedExecContext(mode: mode, senderAllowed: senderAllowed),
            headless: runtimeContext.headless
        )
    }

    private func canEscalateSandboxDenial(toolName: String) async -> Bool {
        guard perCallElevationModes[toolName] != nil else { return false }
        let identity = await resolveSenderIdentity()
        return ElevatedSenderResolver.isAllowed(identity: identity, allowlist: elevatedAllowlist)
    }

    private static func escalationUnavailableMessage() -> String {
        "Command requires elevated execution outside the sandbox, but elevation is not available for this tool or sender. Sandbox denied with exit 126."
    }

    private func bashSuccess(_ toolCall: ToolCall, _ result: ExecSupervisorResult) -> ToolResult {
        if let taskID = result.backgroundTaskID {
            return ok(toolCall, "background task: \(taskID)")
        }
        return ok(toolCall, result.stdout)
    }

    private func bash(_ toolCall: ToolCall) async -> ToolResult {
        let command = extractString(from: toolCall.arguments, key: "command") ?? ""
        let runInBackground = extractBool(from: toolCall.arguments, key: "run_in_background") ?? false
        let usePty = extractBool(from: toolCall.arguments, key: "use_pty") ?? false
        let elevated = extractBool(from: toolCall.arguments, key: "elevated") ?? false

        if elevated {
            return await runBashElevated(
                toolCall: toolCall,
                command: command,
                runInBackground: runInBackground,
                usePty: usePty
            )
        }

        do {
            let context = await elevatedRuntimeContext(toolName: Self.bashToolName, elevated: false)
            let result = try await bashRunner(for: context).runBash(
                command: command,
                runInBackground: runInBackground,
                usePty: usePty,
                approvalContextLines: []
            )
            return bashSuccess(toolCall, result)
        } catch let error as SandboxBackendError where error.isSandboxExecDenial {
            if await canEscalateSandboxDenial(toolName: Self.bashToolName) {
                return await runBashElevated(
                    toolCall: toolCall,
                    command: command,
                    runInBackground: runInBackground,
                    usePty: usePty,
                    sandboxDenial: error
                )
            }
            return err(toolCall, Self.escalationUnavailableMessage())
        } catch let error as SandboxBackendError {
            return err(toolCall, sandboxErrorMessage(error))
        } catch {
            return err(toolCall, "Sandbox execution failed: \(error.localizedDescription)")
        }
    }

    private func runBashElevated(
        toolCall: ToolCall,
        command: String,
        runInBackground: Bool,
        usePty: Bool,
        sandboxDenial: SandboxBackendError? = nil
    ) async -> ToolResult {
        let context = await elevatedRuntimeContext(toolName: Self.bashToolName, elevated: true)
        guard context.elevated.isActive else {
            if sandboxDenial != nil {
                return err(toolCall, Self.escalationUnavailableMessage())
            }
            return err(toolCall, "Elevated execution is not allowed for this sender or tool")
        }
        let approvalContextLines = sandboxDenial != nil
            ? ["Sandbox denied execution with exit 126."]
            : []
        do {
            let result = try await bashRunner(for: context).runBash(
                command: command,
                runInBackground: runInBackground,
                usePty: usePty,
                approvalContextLines: approvalContextLines
            )
            return bashSuccess(toolCall, result)
        } catch let error as SandboxBackendError {
            return err(toolCall, sandboxErrorMessage(error))
        } catch {
            return err(toolCall, "Elevated execution failed: \(error.localizedDescription)")
        }
    }

    private func process(_ toolCall: ToolCall) async -> ToolResult {
        let taskID = extractString(from: toolCall.arguments, key: "task_id") ?? ""
        let action = extractString(from: toolCall.arguments, key: "action") ?? "poll"
        if action == "kill" {
            let killed = await bashExecutor(for: runtimeContext).killProcess(taskID: taskID)
            if killed {
                return ok(toolCall, "killed \(taskID)")
            }
            return err(toolCall, "task not found")
        }
        guard let session = await bashExecutor(for: runtimeContext).pollProcess(taskID: taskID) else {
            return err(toolCall, "task not found")
        }
        return ok(toolCall, "\(session.status)\n\(session.stdout)")
    }

    private func processSendKeys(_ toolCall: ToolCall) async -> ToolResult {
        let taskID = extractString(from: toolCall.arguments, key: "task_id") ?? ""
        let keys = extractString(from: toolCall.arguments, key: "keys") ?? ""
        do {
            try await bashExecutor(for: runtimeContext).sendKeys(taskID: taskID, keys: keys)
            return ok(toolCall, "sent keys")
        } catch let error as SandboxBackendError {
            return err(toolCall, sandboxErrorMessage(error))
        } catch {
            return err(toolCall, error.localizedDescription)
        }
    }

    private func ok(_ toolCall: ToolCall, _ content: String) -> ToolResult {
        ToolResult(success: true, content: content, metadata: .object(["source": .string("workspace_fs")]), toolCallId: toolCall.id)
    }

    private func err(_ toolCall: ToolCall, _ message: String) -> ToolResult {
        ToolResult(success: false, content: "", metadata: .object(["source": .string("workspace_fs")]), toolCallId: toolCall.id, error: message)
    }

    private func extractString(from arguments: JSON, key: String) -> String? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    private func extractBool(from arguments: JSON, key: String) -> Bool? {
        guard case .object(let dict) = arguments, let value = dict[key] else { return nil }
        if case .boolean(let b) = value { return b }
        return nil
    }

    private func notifyMemoryWrite(_ path: String) async {
        guard let memoryDirectory = runtimeContext.memoryDirectory,
              AgentMemoryPathResolver.isPathInsideMemoryDirectory(path, memoryDirectory: URL(fileURLWithPath: memoryDirectory)) else {
            return
        }
        await onMemoryWrite?(path)
    }

    private func pathErrorMessage(_ error: Error) -> String {
        switch error {
        case WorkspaceFilesystemError.outsideAllowedRoots:
            return "Path is outside the allowed workspace or memory directory"
        case WorkspaceFilesystemError.symlinkEscape:
            return "Path escapes allowed roots via symlink"
        case WorkspaceFilesystemError.symlinkLoop:
            return "Path contains a symlink loop"
        case WorkspaceFilesystemError.writeDenied:
            return "Path outside memory directory"
        case WorkspaceFilesystemError.invalidPath:
            return "Invalid path"
        case WorkspaceFilesystemError.notFound(let path):
            return "File not found: \(path)"
        case SandboxBackendError.pathEscapes:
            return "Path escapes workspace boundary"
        default:
            return "Path not allowed"
        }
    }

    private func sandboxErrorMessage(_ error: SandboxBackendError) -> String {
        switch error {
        case .emptyCommand:
            return "Command is empty"
        case .sandboxUnavailable:
            return "Sandbox execution is unavailable (Seatbelt/bwrap tooling missing). Full host exec requires elevated: true on bash with approval policy."
        case .nonZeroExit(let code, let output):
            return "Command failed with exit \(code): \(output)"
        case .pathEscapes(let path):
            return "Path escapes boundary: \(path)"
        case .runtimeNotFound(let id):
            return "Runtime not found: \(id)"
        case .commandFailed(let reason):
            return reason
        case .notRegistered(let id):
            return "Backend not registered: \(id)"
        case .duplicateRegistration(let id):
            return "Duplicate backend: \(id)"
        case .hostToolMissing(let tool, let location):
            if location == "gateway" {
                return "SSH backend requires \(tool) on the gateway host"
            }
            return "SSH backend requires \(tool) on \(location)"
        }
    }
}
