import Foundation

public struct OpenShellSandboxSettings: Sendable, Equatable, Codable {
    public var sandboxName: String?
    public var workdir: String
    public var computeDriver: String
    public var fromImage: String
    public var keepAliveCommand: [String]

    public init(
        sandboxName: String? = nil,
        workdir: String = "/workspace",
        computeDriver: String = "docker",
        fromImage: String = "base",
        keepAliveCommand: [String] = ["sleep", "infinity"]
    ) {
        self.sandboxName = sandboxName
        self.workdir = workdir
        self.computeDriver = computeDriver
        self.fromImage = fromImage
        self.keepAliveCommand = keepAliveCommand
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

enum OpenShellSandboxDriverConfig {
    private struct BindMountSpec: Encodable {
        let type: String
        let source: String
        let target: String
        let read_only: Bool

        init(source: String, target: String) {
            self.type = "bind"
            self.source = source
            self.target = target
            self.read_only = false
        }
    }

    private struct DriverBlock: Encodable {
        let mounts: [BindMountSpec]
    }

    static func bindMountJSON(source: String, target: String, driver: String) throws -> String {
        let block = DriverBlock(mounts: [BindMountSpec(source: source, target: target)])
        let envelope: [String: DriverBlock] = [driver: block]
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SandboxBackendError.commandFailed("failed to encode OpenShell driver config")
        }
        return json
    }
}

enum OpenShellSandboxConfigMatch {
    static func matches(running: Bool, labelHash: String?, currentHash: String) -> Bool {
        !running || labelHash == currentHash
    }
}

struct OpenShellSandboxDescribeResult: Sendable, Equatable {
    let running: Bool
    let configHash: String?

    static func parse(data: Data) throws -> OpenShellSandboxDescribeResult {
        let payload = try JSONDecoder().decode(DescribePayload.self, from: data)
        let labels = payload.labels ?? payload.metadata?.labels ?? [:]
        let configHash = labels["sah.configHash"]
        let phase = payload.phase?.lowercased() ?? ""
        let running = phase == "ready" || payload.running == true
        return OpenShellSandboxDescribeResult(running: running, configHash: configHash)
    }

    private struct DescribePayload: Decodable {
        let phase: String?
        let running: Bool?
        let labels: [String: String]?
        let metadata: Metadata?

        struct Metadata: Decodable {
            let labels: [String: String]?
        }
    }
}

enum OpenShellSandboxInspect {
    static func describe(cliPath: String, sandboxName: String) async throws -> OpenShellSandboxDescribeResult? {
        let argv = OpenShellSandboxArgv.describe(cliPath: cliPath, sandboxName: sandboxName)
        let result = try await ShellProcessRunner.run(argv: argv)
        guard result.exitCode == 0 else { return nil }
        return try OpenShellSandboxDescribeResult.parse(data: result.stdout)
    }
}

enum OpenShellSandboxArgv {
    static func exec(
        cliPath: String,
        sandboxName: String,
        workdir: String,
        command: String,
        usePty: Bool,
        env: [String: String] = [:]
    ) throws -> [String] {
        var argv = [cliPath, "sandbox", "exec", "-n", sandboxName, "--workdir", workdir]
        argv += try OpenShellSandboxEnvPolicy.execFlags(env: env)
        if usePty { argv.append("--tty") }
        argv.append(contentsOf: ["--", "/bin/bash", "-lc", command])
        return argv
    }

    static func create(
        cliPath: String,
        sandboxName: String,
        configHash: String,
        fromImage: String,
        driverConfigJSON: String,
        keepAliveCommand: [String]
    ) -> [String] {
        var argv = [
            cliPath, "sandbox", "create",
            "--name", sandboxName,
            "--label", "sah.configHash=\(configHash)",
            "--from", fromImage,
            "--driver-config-json", driverConfigJSON,
            "--",
        ]
        argv.append(contentsOf: keepAliveCommand)
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
    private let configHash: String

    init(params: CreateSandboxBackendParams) throws {
        let openshell = params.config.openshell ?? OpenShellSandboxSettings()
        self.settings = openshell
        self.hostWorkspace = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.sandboxName = openshell.sandboxName ?? "sah-\(params.scopeKey)"
        self.mirrorRoot = SandboxHostPaths.openshellMirrorRoot(scopeKey: params.scopeKey).path
        self.workdir = openshell.workdir
        self.configHash = SandboxConfigHash.compute(config: params.config)
        self.runtimeId = sandboxName
        self.runtimeLabel = sandboxName
        self.configLabel = sandboxName
        self.env = nil
    }

    private func ensureMirrorDirectory() throws {
        try SandboxHostPaths.ensureDirectory(at: URL(fileURLWithPath: mirrorRoot, isDirectory: true))
    }

    private func ensureSandbox(cliPath: String) async throws {
        try ensureMirrorDirectory()
        if let describe = try await OpenShellSandboxInspect.describe(cliPath: cliPath, sandboxName: sandboxName),
           describe.running,
           OpenShellSandboxConfigMatch.matches(running: true, labelHash: describe.configHash, currentHash: configHash) {
            return
        }
        _ = try await ShellProcessRunner.run(argv: OpenShellSandboxArgv.delete(cliPath: cliPath, sandboxName: sandboxName))
        let driverConfigJSON = try OpenShellSandboxDriverConfig.bindMountJSON(
            source: mirrorRoot,
            target: workdir,
            driver: settings.computeDriver
        )
        let createArgv = OpenShellSandboxArgv.create(
            cliPath: cliPath,
            sandboxName: sandboxName,
            configHash: configHash,
            fromImage: settings.fromImage,
            driverConfigJSON: driverConfigJSON,
            keepAliveCommand: settings.keepAliveCommand
        )
        let result = try await ShellProcessRunner.run(argv: createArgv)
        guard result.exitCode == 0 else {
            throw SandboxBackendError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private func syncMirrorToHost() async throws {
        try await WorkspaceMirrorSync.shared.syncAfter(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        let trimmed = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxBackendError.emptyCommand }
        let cliPath = try OpenShellHostTools.requireCLI()
        try await ensureSandbox(cliPath: cliPath)
        try await WorkspaceMirrorSync.shared.syncBefore(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
        let argv = try OpenShellSandboxArgv.exec(
            cliPath: cliPath,
            sandboxName: sandboxName,
            workdir: workdir,
            command: trimmed,
            usePty: params.usePty,
            env: params.env
        )
        return SandboxBackendExecSpec(argv: argv, cwd: nil, usePty: params.usePty)
    }

    public func finalizeExec(params: SandboxFinalizeExecParams) async throws {
        try await syncMirrorToHost()
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        let cliPath = try OpenShellHostTools.requireCLI()
        try await ensureSandbox(cliPath: cliPath)
        try await WorkspaceMirrorSync.shared.syncBefore(hostRoot: hostWorkspace, mirrorRoot: mirrorRoot)
        let argv = try OpenShellSandboxArgv.exec(
            cliPath: cliPath,
            sandboxName: sandboxName,
            workdir: workdir,
            command: params.script,
            usePty: false,
            env: params.env
        )
        let result = try await ShellProcessRunner.run(argv: argv, stdin: params.stdin)
        try await syncMirrorToHost()
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
        let currentHash = SandboxConfigHash.compute(config: params.config)
        let describe = try await OpenShellSandboxInspect.describe(cliPath: cliPath, sandboxName: sandboxName)
        let running = describe?.running ?? false
        let configMatches = OpenShellSandboxConfigMatch.matches(
            running: running,
            labelHash: describe?.configHash,
            currentHash: currentHash
        )
        return SandboxBackendRuntimeInfo(
            runtimeId: sandboxName,
            running: running,
            configMatches: configMatches,
            runtimeLabel: sandboxName
        )
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        guard let openshell = params.config.openshell else { return }
        let cliPath = try OpenShellHostTools.requireCLI()
        let sandboxName = openshell.sandboxName ?? "sah-\(params.scopeKey)"
        let mirrorRoot = SandboxHostPaths.openshellMirrorRoot(scopeKey: params.scopeKey).path
        _ = try await ShellProcessRunner.run(argv: OpenShellSandboxArgv.delete(cliPath: cliPath, sandboxName: sandboxName))
        await WorkspaceMirrorSync.shared.remove(mirrorRoot: mirrorRoot)
    }
}
