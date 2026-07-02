import Foundation
import Logging

public struct ExecRuntimeContext: Sendable {
    public let sessionKey: String
    public let agentID: String
    public let isMainSession: Bool
    public let memoryDirectory: String?
    public let memoryWriteOnly: Bool
    public let senderIdentity: ExecSenderIdentity
    public let elevated: ElevatedExecContext
    public let headless: Bool

    public init(
        sessionKey: String,
        agentID: String,
        isMainSession: Bool,
        memoryDirectory: String? = nil,
        memoryWriteOnly: Bool = false,
        senderIdentity: ExecSenderIdentity = .cliDefault,
        elevated: ElevatedExecContext = ElevatedExecContext(mode: .off, senderAllowed: false),
        headless: Bool = false
    ) {
        self.sessionKey = sessionKey
        self.agentID = agentID
        self.isMainSession = isMainSession
        self.memoryDirectory = memoryDirectory
        self.memoryWriteOnly = memoryWriteOnly
        self.senderIdentity = senderIdentity
        self.elevated = elevated
        self.headless = headless
    }
}

public struct ExecRuntimeService: Sendable {
    public let workspaceRoot: String
    public let agentWorkspaceDir: String
    public let globalSettings: SandboxGlobalSettings
    public let approvalDelivery: any ExecApprovalDelivering
    private let logger: Logger?

    public init(
        workspaceRoot: String,
        agentWorkspaceDir: String? = nil,
        globalSettings: SandboxGlobalSettings = SandboxGlobalSettings(),
        approvalDelivery: any ExecApprovalDelivering = DefaultExecApprovalDelivery(),
        logger: Logger? = nil
    ) {
        self.workspaceRoot = FilesystemCanonicalPath.resolve(workspaceRoot)
        self.agentWorkspaceDir = FilesystemCanonicalPath.resolve(agentWorkspaceDir ?? workspaceRoot)
        self.globalSettings = globalSettings
        self.approvalDelivery = approvalDelivery
        self.logger = logger
        SandboxBackendRegistry.bootstrapBuiltInsIfNeeded()
    }

    public func resolvedConfig(context: ExecRuntimeContext) -> SandboxConfig {
        SandboxConfigResolver.resolve(
            global: globalSettings,
            agentID: context.agentID,
            sessionKey: context.sessionKey,
            isMainSession: context.isMainSession
        )
    }

    public func backendHandle(context: ExecRuntimeContext) async throws -> any SandboxBackendHandle {
        let config = resolvedConfig(context: context)
        let scopeKey = SandboxConfigResolver.resolveScopeKey(
            scope: config.scope,
            sessionKey: context.sessionKey,
            agentID: context.agentID
        )
        let handle = try await SandboxBackendRegistry.createHandle(params: CreateSandboxBackendParams(
            sessionKey: context.sessionKey,
            scopeKey: scopeKey,
            workspaceDir: workspaceRoot,
            agentWorkspaceDir: agentWorkspaceDir,
            config: config,
            memoryDirectory: context.memoryDirectory
        ))
        let entry = SandboxRuntimeEntry(
            runtimeId: handle.runtimeId,
            sessionKey: context.sessionKey,
            scopeKey: scopeKey,
            backendId: handle.id,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            lastUsedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            configHash: SandboxConfigHash.compute(config: config),
            runtimeLabel: handle.runtimeLabel
        )
        try? await SandboxRuntimeRegistry.shared.upsert(entry)
        return handle
    }

    public func fsBridge(context: ExecRuntimeContext) async throws -> any SandboxFsBridge {
        let config = resolvedConfig(context: context)
        let manifest = try SandboxBackendRegistry.manifest(for: config.backend)
        let bridgeContext = SandboxFsBridgeContext(
            workspaceRoot: workspaceRoot,
            agentWorkspaceDir: agentWorkspaceDir,
            memoryDirectory: context.memoryDirectory
        )
        switch manifest.workspaceModel {
        case .hostCanonical, .mirror:
            return LocalHostFsBridge(context: bridgeContext, memoryWriteOnly: context.memoryWriteOnly)
        case .remoteCanonical:
            let handle = try await backendHandle(context: context)
            if let bridge = handle.createFsBridge(params: SandboxFsBridgeParams(context: bridgeContext, memoryWriteOnly: context.memoryWriteOnly)) {
                return bridge
            }
            throw SandboxBackendError.commandFailed("remote FS bridge unavailable for backend \(config.backend)")
        }
    }

    public func runShell(
        command: String,
        context: ExecRuntimeContext,
        runInBackground: Bool = false,
        requiresApproval: Bool = false,
        usePty: Bool = false,
        approvalContextLines: [String] = []
    ) async throws -> ExecSupervisorResult {
        if context.elevated.isActive {
            if ElevatedExecHost.requiresExecApproval(mode: context.elevated.mode) {
                try await requestExecApproval(
                    command: command,
                    context: context,
                    approvalContextLines: approvalContextLines
                )
            }
            return try await ElevatedExecHost.run(
                context: context.elevated,
                params: SandboxBuildExecSpecParams(command: command, workdir: workspaceRoot),
                execApprovalGranted: true
            )
        }
        if requiresApproval {
            try await requestExecApproval(
                command: command,
                context: context,
                approvalContextLines: approvalContextLines
            )
        }
        let handle = try await backendHandle(context: context)
        let params = SandboxBuildExecSpecParams(command: command, workdir: workspaceRoot, usePty: usePty)
        if runInBackground {
            return try await ExecSupervisor.runBackground(sessionSlug: context.sessionKey, handle: handle, params: params)
        }
        let config = resolvedConfig(context: context)
        let result = try await ExecSupervisor.runForeground(
            sessionSlug: context.sessionKey,
            handle: handle,
            params: params,
            budgetSeconds: config.assistantBlockingBudgetSeconds
        )
        try? await SandboxRuntimeRegistry.shared.touch(runtimeId: handle.runtimeId)
        if result.backgroundTaskID != nil {
            return result
        }
        if result.exitCode != 0 {
            throw SandboxBackendError.nonZeroExit(result.exitCode, result.stdout + result.stderr)
        }
        return result
    }

    private func requestExecApproval(
        command: String,
        context: ExecRuntimeContext,
        approvalContextLines: [String] = []
    ) async throws {
        let title = context.elevated.isActive
            ? "Run command outside the sandbox?"
            : "Approve shell command?"
        var contextLines = [command]
        if !approvalContextLines.isEmpty {
            contextLines.append(contentsOf: approvalContextLines)
        } else if context.elevated.isActive {
            contextLines.append("Runs on the host outside the sandbox.")
        }
        let presentation = ApprovalPresentation.standard(
            title: title,
            context: contextLines
        )
        let request = ExecApprovalRequest(
            id: UUID().uuidString,
            command: command,
            title: title,
            description: command,
            allowsDurableBypass: !context.elevated.isActive,
            presentation: presentation
        )
        switch await approvalDelivery.requestApproval(request, headless: context.headless) {
        case .approved: return
        case .denied(let reason), .headlessDenied(let reason):
            throw SandboxBackendError.commandFailed(reason)
        case .deferred(let message):
            throw SandboxBackendError.commandFailed(message)
        }
    }

    public func runShellCommand(
        params: SandboxBackendCommandParams,
        context: ExecRuntimeContext
    ) async throws -> SandboxBackendCommandResult {
        let handle = try await backendHandle(context: context)
        return try await handle.runShellCommand(params: params)
    }
}
