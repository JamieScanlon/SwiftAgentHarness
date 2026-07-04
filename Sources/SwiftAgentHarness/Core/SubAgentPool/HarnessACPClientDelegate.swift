import Foundation
import SwiftAgentKit
import SwiftAgentKitACP

struct SubAgentACPToolDispatchContext: Sendable {
    let conversation: ModelConversation
    let workspaceRoot: String
    let execRuntime: ExecRuntimeService
    let runtimeContext: ExecRuntimeContext
    let gateway: any ToolSystemGatewaying
    let toolPolicy: ToolPolicyConfiguration
    let trustPolicy: TrustPolicyConfiguration
    let modePolicyContext: ModePolicyContext
    var runtimeConfiguration: AgentRuntimeTurnConfiguration
    let subAgentPool: any SubAgentPooling
    let toolEntries: [ToolRegistryEntry]
    let permissionPolicy: SubAgentPermissionPolicy
    let permissionAlreadyGranted: Bool
    let delegateToolName: String?
}

enum ACPTerminalWaitPolicy {
    static let pollIntervalNanoseconds: UInt64 = 100_000_000
    static let maxPolls = 3000
}

struct HarnessACPClientDelegate: ACPClientDelegate {
    let context: SubAgentACPToolDispatchContext
    let executor: LocalSandboxBashExecutor
    let lifecycleID: String

    func readTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.readFileToolName)
        let bridge = try await context.execRuntime.fsBridge(context: context.runtimeContext)
        _ = try PathPolicy.resolveReadablePath(
            raw: request.path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.runtimeContext.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: context.runtimeContext.memoryWriteOnly
        )
        let data = try await bridge.readFile(path: request.path)
        var content = String(data: data, encoding: .utf8) ?? ""
        if let line = request.line, line > 0 {
            let lines = content.components(separatedBy: .newlines)
            let start = line - 1
            let end = min(lines.count, start + (request.limit ?? lines.count))
            content = lines[start..<end].joined(separator: "\n")
        }
        return ACPReadTextFileResponse(content: content)
    }

    func writeTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.writeFileToolName)
        let bridge = try await context.execRuntime.fsBridge(context: context.runtimeContext)
        let path = try PathPolicy.resolveWritablePath(
            raw: request.path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.runtimeContext.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: context.runtimeContext.memoryWriteOnly
        )
        try MemoryContentScanner.validateWriteIfMemoryTarget(
            path: path,
            memoryDirectory: context.runtimeContext.memoryDirectory.map { URL(fileURLWithPath: $0) },
            content: request.content
        ).get()
        try await bridge.writeFile(path: request.path, content: Data(request.content.utf8))
        return ACPWriteTextFileResponse()
    }

    func requestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse {
        if context.permissionAlreadyGranted || context.permissionPolicy == .auto {
            if let first = request.options.first {
                return ACPRequestPermissionResponse(outcome: .selected(optionId: first.optionId))
            }
        }
        return await SubAgentACPPermissionCoordinator.shared.waitForResolution(
            lifecycleID: lifecycleID,
            parentConversationID: context.conversation.id,
            runID: context.conversation.currentRunID,
            delegateToolName: context.delegateToolName,
            defaultTrustLevel: SubAgentTrustLevel.unknownParty.rawValue,
            permissionPolicy: context.permissionPolicy.rawValue,
            request: request,
            policy: context.permissionPolicy
        )
    }

    func createTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.bashToolName)
        let command = ACPTerminalRPCTranslator.shellCommand(from: request)
        let runInBackground = request.command == nil
        let result = try await executor.runBash(command: command, runInBackground: runInBackground)
        if let taskID = result.backgroundTaskID {
            return ACPCreateTerminalResponse(terminalId: taskID)
        }
        let terminalID = "foreground-\(lifecycleID)-\(UUID().uuidString.lowercased())"
        await ACPTerminalForegroundOutputRegistry.shared.store(
            terminalID: terminalID,
            stdout: result.stdout,
            exitCode: Int(result.exitCode)
        )
        return ACPCreateTerminalResponse(terminalId: terminalID)
    }

    func terminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.processToolName)
        if let stored = await ACPTerminalForegroundOutputRegistry.shared.snapshot(terminalID: request.terminalId) {
            let exitStatus = stored.exitCode.map { ACPTerminalExitStatus(exitCode: $0) }
            return ACPTerminalOutputResponse(output: stored.stdout, exitStatus: exitStatus)
        }
        guard let snap = await executor.terminalSnapshot(taskID: request.terminalId) else {
            throw JSONRPCConnectionError.invalidRequest
        }
        let exitStatus = snap.exitCode.map { ACPTerminalExitStatus(exitCode: Int($0)) }
        return ACPTerminalOutputResponse(output: snap.output, exitStatus: exitStatus)
    }

    func waitForTerminalExit(_ request: ACPWaitForExitRequest) async throws -> ACPWaitForExitResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.processToolName)
        if let stored = await ACPTerminalForegroundOutputRegistry.shared.snapshot(terminalID: request.terminalId) {
            return ACPWaitForExitResponse(
                exitStatus: ACPTerminalExitStatus(exitCode: stored.exitCode ?? 0)
            )
        }
        let maxPolls = ACPTerminalWaitPolicy.maxPolls
        for _ in 0..<maxPolls {
            if let snap = await executor.terminalSnapshot(taskID: request.terminalId),
               let code = snap.exitCode {
                return ACPWaitForExitResponse(exitStatus: ACPTerminalExitStatus(exitCode: Int(code)))
            }
            try await Task.sleep(nanoseconds: ACPTerminalWaitPolicy.pollIntervalNanoseconds)
        }
        return ACPWaitForExitResponse(
            exitStatus: ACPTerminalExitStatus(exitCode: nil, signal: nil)
        )
    }

    func killTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse {
        try await requireTool(WorkspaceFilesystemToolProvider.processToolName)
        await executor.killProcess(taskID: request.terminalId)
        await ACPTerminalForegroundOutputRegistry.shared.remove(terminalID: request.terminalId)
        return ACPKillTerminalResponse()
    }

    func releaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse {
        await ACPTerminalForegroundOutputRegistry.shared.remove(terminalID: request.terminalId)
        return ACPReleaseTerminalResponse()
    }

    private func requireTool(_ toolName: String) async throws {
        guard let entry = context.toolEntries.first(where: { $0.name == toolName }) else {
            throw JSONRPCConnectionError.methodNotFound(toolName)
        }
        var childConfiguration = context.runtimeConfiguration
        childConfiguration.inputTrustRaw = SubAgentTrustLevel.unknownParty.rawValue
        let decision = context.gateway.evaluateAvailability(
            entry: entry,
            conversation: context.conversation,
            modePolicyContext: context.modePolicyContext,
            configuration: childConfiguration,
            toolPolicy: context.toolPolicy,
            trustPolicy: context.trustPolicy,
            subAgentToolClassifier: context.subAgentPool
        )
        guard decision.allowed else {
            throw JSONRPCConnectionError.invalidRequest
        }
    }
}

enum ACPTerminalRPCTranslator {
    static func shellCommand(from request: ACPCreateTerminalRequest) -> String {
        if let command = request.command, !command.isEmpty {
            if let args = request.args, !args.isEmpty {
                let escapedArgs = args.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
                return "\(command) \(escapedArgs)"
            }
            return command
        }
        return "true"
    }
}

actor ACPTerminalForegroundOutputRegistry {
    static let shared = ACPTerminalForegroundOutputRegistry()

    struct Snapshot: Sendable {
        var stdout: String
        var exitCode: Int?
        var storedAt: Date
    }

    private var entries: [String: Snapshot] = [:]
    private let defaultTTL: TimeInterval = 3600

    func store(terminalID: String, stdout: String, exitCode: Int?) {
        sweepExpired(maxAge: defaultTTL)
        entries[terminalID] = Snapshot(stdout: stdout, exitCode: exitCode, storedAt: Date())
    }

    func snapshot(terminalID: String) -> Snapshot? {
        sweepExpired(maxAge: defaultTTL)
        return entries[terminalID]
    }

    func remove(terminalID: String) {
        entries.removeValue(forKey: terminalID)
    }

    func sweep(lifecycleIDPrefix: String) {
        let prefix = "foreground-\(lifecycleIDPrefix)-"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    private func sweepExpired(maxAge: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries = entries.filter { $0.value.storedAt >= cutoff }
    }
}
