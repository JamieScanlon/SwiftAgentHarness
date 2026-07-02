import Foundation

public struct OpenShellSandboxSettings: Sendable, Equatable, Codable {
    public var sandboxName: String?
    public var workdir: String

    public init(sandboxName: String? = nil, workdir: String = "/workspace") {
        self.sandboxName = sandboxName
        self.workdir = workdir
    }
}

enum OpenShellHostTools {
    static let cliCandidates = ["/opt/homebrew/bin/openshell", "/usr/local/bin/openshell", "/usr/bin/openshell"]

    static func cliPath(fileManager: FileManager = .default) -> String? {
        cliCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func requireCLI(fileManager: FileManager = .default) throws -> String {
        guard let path = cliPath(fileManager: fileManager) else {
            throw SandboxBackendError.hostToolMissing(tool: "openshell", location: "gateway")
        }
        return path
    }
}

enum OpenShellSandboxArgv {
    static func exec(cliPath: String, sandboxName: String, workdir: String, command: String, usePty: Bool) -> [String] {
        var argv = [cliPath, "exec", "--sandbox", sandboxName, "--workdir", workdir]
        if usePty { argv.append("--tty") }
        argv.append(contentsOf: ["--", "/bin/bash", "-lc", command])
        return argv
    }

    static func delete(cliPath: String, sandboxName: String) -> [String] {
        [cliPath, "sandbox", "delete", sandboxName]
    }

    static func describe(cliPath: String, sandboxName: String) -> [String] {
        [cliPath, "sandbox", "describe", "--json", sandboxName]
    }
}

public struct OpenShellSandboxBackendHandle: SandboxBackendHandle {
    public let id: SandboxBackendID = "openshell"
    public let runtimeId: String
    public let runtimeLabel: String
    public let workdir: String
    public let env: [String: String]?
    public let configLabel: String?
    public let configLabelKind: String? = "Sandbox"
    public let capabilities: SandboxBackendCapabilities? = SandboxBackendManifests.openshell.capabilities

    private let settings: OpenShellSandboxSettings
    private let hostWorkspace: String
    private let mirrorRoot: String
    private let sandboxName: String

    init(params: CreateSandboxBackendParams) throws {
        let openshell = params.config.openshell ?? OpenShellSandboxSettings()
        self.settings = openshell
        self.hostWorkspace = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.sandboxName = openshell.sandboxName ?? "sah-\(params.scopeKey)"
        self.mirrorRoot = "/tmp/sah-openshell-\(params.scopeKey)"
        self.workdir = openshell.workdir
        self.runtimeId = sandboxName
        self.runtimeLabel = sandboxName
        self.configLabel = sandboxName
        self.env = nil
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        let trimmed = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxBackendError.emptyCommand }
        let cliPath = try OpenShellHostTools.requireCLI()
        try await WorkspaceMirrorSync.shared.syncBefore(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
        let argv = OpenShellSandboxArgv.exec(
            cliPath: cliPath,
            sandboxName: sandboxName,
            workdir: workdir,
            command: trimmed,
            usePty: params.usePty
        )
        return SandboxBackendExecSpec(argv: argv, env: params.env, cwd: nil, usePty: params.usePty)
    }

    public func finalizeExec(params: SandboxFinalizeExecParams) async throws {
        guard params.status == .completed else { return }
        try await WorkspaceMirrorSync.shared.syncAfter(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        let cliPath = try OpenShellHostTools.requireCLI()
        try await WorkspaceMirrorSync.shared.syncBefore(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
        let argv = OpenShellSandboxArgv.exec(
            cliPath: cliPath,
            sandboxName: sandboxName,
            workdir: workdir,
            command: params.script,
            usePty: false
        )
        let result = try await ShellProcessRunner.run(argv: argv, env: params.env, stdin: params.stdin)
        if result.exitCode == 0 {
            try await WorkspaceMirrorSync.shared.syncAfter(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
        }
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    public func createFsBridge(params: SandboxFsBridgeParams) -> (any SandboxFsBridge)? {
        nil
    }
}

public struct OpenShellSandboxBackendManager: SandboxBackendManager {
    public init() {}

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        let cliPath = try OpenShellHostTools.requireCLI()
        guard let openshell = params.config.openshell else {
            throw SandboxBackendError.commandFailed("OpenShell settings missing")
        }
        let sandboxName = openshell.sandboxName ?? "sah-\(params.scopeKey)"
        let argv = OpenShellSandboxArgv.describe(cliPath: cliPath, sandboxName: sandboxName)
        let result = try await ShellProcessRunner.run(argv: argv)
        return SandboxBackendRuntimeInfo(
            runtimeId: sandboxName,
            running: result.exitCode == 0,
            configMatches: true,
            runtimeLabel: sandboxName
        )
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        guard let openshell = params.config.openshell else { return }
        let cliPath = try OpenShellHostTools.requireCLI()
        let sandboxName = openshell.sandboxName ?? "sah-\(params.scopeKey)"
        let mirrorRoot = "/tmp/sah-openshell-\(params.scopeKey)"
        _ = try await ShellProcessRunner.run(argv: OpenShellSandboxArgv.delete(cliPath: cliPath, sandboxName: sandboxName))
        await WorkspaceMirrorSync.shared.remove(mirrorRoot: mirrorRoot)
    }
}
