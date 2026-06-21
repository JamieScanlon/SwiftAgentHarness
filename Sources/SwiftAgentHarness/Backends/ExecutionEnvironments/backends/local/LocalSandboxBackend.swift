import Foundation
import Logging

public struct LocalSandboxBackendHandle: SandboxBackendHandle {
    public let id: SandboxBackendID = "local"
    public let runtimeId: String
    public let runtimeLabel: String = "Local"
    public let workdir: String
    public let env: [String: String]?
    public let configLabel: String? = "host"
    public let configLabelKind: String? = "Target"
    public let capabilities: SandboxBackendCapabilities? = SandboxBackendManifests.local.capabilities

    private let memoryDirectory: String?
    private let logger: Logger?

    init(params: CreateSandboxBackendParams, logger: Logger? = nil) {
        self.runtimeId = "local-\(params.scopeKey)"
        self.workdir = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.memoryDirectory = params.memoryDirectory
        self.env = nil
        self.logger = logger
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        let trimmed = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxBackendError.emptyCommand }
        guard LocalExecArgv.isSandboxAvailable else { throw SandboxBackendError.sandboxUnavailable }
        let cwd = params.workdir ?? workdir
        let childEnv = SandboxChildEnvironment.build(overlay: params.env, cwd: cwd)
        let argv = LocalExecArgv.sandboxed(command: trimmed, workspaceRoot: workdir, memoryDirectory: memoryDirectory, env: childEnv)
        return SandboxBackendExecSpec(
            argv: argv,
            env: childEnv,
            cwd: cwd,
            usePty: params.usePty,
            stdinMode: .none,
            inheritHostEnvironment: false
        )
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        guard LocalExecArgv.isSandboxAvailable else { throw SandboxBackendError.sandboxUnavailable }
        let cwd = params.workdir ?? workdir
        let childEnv = SandboxChildEnvironment.build(overlay: params.env, cwd: cwd)
        let argv = LocalExecArgv.sandboxed(command: params.script, workspaceRoot: workdir, memoryDirectory: memoryDirectory, env: childEnv)
        let result = try await ShellProcessRunner.run(
            argv: argv,
            env: childEnv,
            cwd: cwd,
            stdin: params.stdin,
            inheritHostEnvironment: false
        )
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    public func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)? {
        LocalHostFsBridge(context: params.context, memoryWriteOnly: params.memoryWriteOnly)
    }
}

public struct LocalSandboxBackendManager: SandboxBackendManager {
    public init() {}

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        SandboxBackendRuntimeInfo(
            runtimeId: "local-\(params.scopeKey)",
            running: true,
            configMatches: true,
            runtimeLabel: "local"
        )
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {}
}

public enum LocalSandboxBackendRegistration {
    public static func register() {
        SandboxBackendRegistry.register(
            SandboxBackendRegistration(
                manifest: SandboxBackendManifests.local,
                factory: { params in LocalSandboxBackendHandle(params: params) },
                manager: LocalSandboxBackendManager()
            )
        )
    }
}

#if os(macOS)
extension LocalSandboxBackendHandle {
    public static func seatbeltProfile(workspaceRoot: String, memoryDirectory: String?) -> String {
        LocalSeatbelt.profile(workspaceRoot: workspaceRoot, memoryDirectory: memoryDirectory)
    }
}
#endif
