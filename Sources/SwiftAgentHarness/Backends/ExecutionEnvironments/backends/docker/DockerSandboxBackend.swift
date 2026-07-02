import Foundation

public enum DockerCredentialRoots {
    public static let blocked: [String] = [
        ".aws", ".ssh", ".config", ".docker", ".gnupg", ".netrc", ".cargo", ".npm",
    ]

    public static func violatesBindSource(_ source: String) -> Bool {
        let components = URL(fileURLWithPath: source).standardizedFileURL.pathComponents
        return blocked.contains { components.contains($0) }
    }
}

public struct DockerSandboxBackendHandle: SandboxBackendHandle {
    public let id: SandboxBackendID = "docker"
    public let runtimeId: String
    public let runtimeLabel: String
    public let workdir: String
    public let env: [String: String]?
    public let configLabel: String?
    public let configLabelKind: String? = "Image"
    public let capabilities: SandboxBackendCapabilities? = SandboxBackendManifests.docker.capabilities

    private let containerName: String
    private let settings: DockerSandboxSettings
    private let hostWorkspace: String
    private let configHash: String

    init(params: CreateSandboxBackendParams) {
        self.containerName = "sah-sandbox-\(params.scopeKey)"
        self.settings = params.config.docker
        self.hostWorkspace = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.configHash = SandboxConfigHash.compute(config: params.config)
        self.workdir = settings.workdir
        self.runtimeId = containerName
        self.runtimeLabel = containerName
        self.configLabel = settings.image
        self.env = nil
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        let trimmed = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxBackendError.emptyCommand }
        try await ensureContainer()
        let argv = try DockerSandboxShellCommand.execArgv(
            containerName: containerName,
            workdir: params.workdir ?? workdir,
            command: trimmed,
            env: params.env,
            usePty: params.usePty
        )
        return SandboxBackendExecSpec(argv: argv, cwd: nil, usePty: params.usePty)
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        try await ensureContainer()
        let argv = try DockerSandboxShellCommand.argv(containerName: containerName, workdir: workdir, params: params)
        let result = try await ShellProcessRunner.run(argv: argv, stdin: params.stdin)
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    public func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)? {
        DockerFsBridge(handle: self, context: params.context, memoryWriteOnly: params.memoryWriteOnly)
    }

    func ensureContainer() async throws {
        if try await DockerSandboxInspect.isRunning(containerName: containerName) {
            let label = try await DockerSandboxInspect.configHash(containerName: containerName)
            if label == configHash { return }
            _ = try await ShellProcessRunner.run(argv: ["docker", "rm", "-f", containerName])
        }
        let runUser = DockerSandboxRunArgs.resolveRunUser(hostWorkspace: hostWorkspace)
        var runArgs = DockerSandboxRunArgs.build(
            containerName: containerName,
            settings: settings,
            hostWorkspace: hostWorkspace,
            runUser: runUser,
            configHash: configHash
        )
        for bind in settings.extraBinds {
            let parts = bind.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let source = try PathPolicy.validateBindSource(parts[0], allowlist: [hostWorkspace])
            guard !DockerCredentialRoots.violatesBindSource(source) else {
                throw SandboxBackendError.pathEscapes(bind)
            }
            runArgs.insert(contentsOf: ["-v", "\(source):\(parts[1])"], at: runArgs.count - 3)
        }
        _ = try await ShellProcessRunner.run(argv: runArgs)
    }
}

public struct DockerFsBridge: SandboxFsBridge {
    private let handle: DockerSandboxBackendHandle
    private let context: SandboxFsBridgeContext
    private let memoryWriteOnly: Bool

    init(handle: DockerSandboxBackendHandle, context: SandboxFsBridgeContext, memoryWriteOnly: Bool) {
        self.handle = handle
        self.context = context
        self.memoryWriteOnly = memoryWriteOnly
    }

    public func stat(path: String) async throws -> SandboxFsStat {
        let resolved = try PathPolicy.resolveReadablePath(
            raw: path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: memoryWriteOnly
        )
        let rel = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.stat(rel: rel))
        return SandboxFsStat.parse(from: result)
    }

    public func readFile(path: String) async throws -> Data {
        let resolved = try PathPolicy.resolveReadablePath(
            raw: path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: memoryWriteOnly
        )
        let rel = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.readFile(rel: rel))
        guard result.code == 0 else { throw SandboxBackendError.commandFailed(String(data: result.stderr, encoding: .utf8) ?? "read failed") }
        return result.stdout
    }

    public func writeFile(path: String, content: Data) async throws {
        let resolved = try PathPolicy.resolveWritablePath(
            raw: path,
            workspaceRoot: context.workspaceRoot,
            memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) },
            memoryWriteOnly: memoryWriteOnly
        )
        let rel = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
        let result = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.writeFile(rel: rel, content: content))
        guard result.code == 0 else { throw SandboxBackendError.commandFailed("write failed") }
    }

    public func mkdir(path: String) async throws {
        let resolved = try PathPolicy.resolveWritablePath(raw: path, workspaceRoot: context.workspaceRoot, memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) }, memoryWriteOnly: memoryWriteOnly)
        let rel = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.mkdir(rel: rel))
    }

    public func rename(from: String, to: String) async throws {
        let src = try PathPolicy.resolveWritablePath(raw: from, workspaceRoot: context.workspaceRoot, memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) }, memoryWriteOnly: memoryWriteOnly)
        let dst = try PathPolicy.resolveWritablePath(raw: to, workspaceRoot: context.workspaceRoot, memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) }, memoryWriteOnly: memoryWriteOnly)
        let relSrc = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: src)
        let relDst = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: dst)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.rename(relSrc: relSrc, relDst: relDst))
    }

    public func remove(path: String) async throws {
        let resolved = try PathPolicy.resolveWritablePath(raw: path, workspaceRoot: context.workspaceRoot, memoryDirectory: context.memoryDirectory.map { URL(fileURLWithPath: $0) }, memoryWriteOnly: memoryWriteOnly)
        let rel = try PathPolicy.toRelativeWorkspacePath(root: context.workspaceRoot, candidate: resolved)
        _ = try await handle.runShellCommand(params: SandboxFsBridgeShellCommands.remove(rel: rel))
    }
}

public struct DockerSandboxBackendManager: SandboxBackendManager {
    public init() {}

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        let name = "sah-sandbox-\(params.scopeKey)"
        let running = try await DockerSandboxInspect.isRunning(containerName: name)
        let currentHash = SandboxConfigHash.compute(config: params.config)
        let labelHash = running ? try await DockerSandboxInspect.configHash(containerName: name) : nil
        let configMatches = DockerSandboxConfigMatch.matches(running: running, labelHash: labelHash, currentHash: currentHash)
        return SandboxBackendRuntimeInfo(runtimeId: name, running: running, configMatches: configMatches, runtimeLabel: name)
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        let name = "sah-sandbox-\(params.scopeKey)"
        _ = try await ShellProcessRunner.run(argv: ["docker", "rm", "-f", name])
    }
}

public enum DockerSandboxBackendRegistration {
    public static func register() {
        SandboxBackendRegistry.register(
            SandboxBackendRegistration(
                manifest: SandboxBackendManifests.docker,
                factory: { params in DockerSandboxBackendHandle(params: params) },
                manager: DockerSandboxBackendManager()
            )
        )
    }
}
