import CryptoKit
import Foundation

public struct NoVNCToken: Sendable, Equatable {
    public let token: String
    public let password: String
    public let expiresAt: Date

    public func url(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.fragment = password
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }
}

public enum NoVNCAuth {
    public static func issue(expirySeconds: TimeInterval = 300) -> NoVNCToken {
        let token = UUID().uuidString
        let password = UUID().uuidString.prefix(12).description
        return NoVNCToken(token: token, password: String(password), expiresAt: Date().addingTimeInterval(expirySeconds))
    }

    public static func isValid(_ token: NoVNCToken) -> Bool {
        token.expiresAt > Date()
    }
}

public struct DockerBrowserSandboxBackendHandle: SandboxBackendHandle {
    public let id: SandboxBackendID = "docker-browser"
    public let runtimeId: String
    public let runtimeLabel: String
    public let workdir: String
    public let env: [String: String]?
    public let configLabel: String?
    public let configLabelKind: String? = "BrowserImage"
    public let capabilities: SandboxBackendCapabilities? = SandboxBackendManifests.dockerBrowser.capabilities

    private let containerName: String
    private let settings: BrowserSandboxSettings
    private let hostWorkspace: String
    private let configHash: String

    init(params: CreateSandboxBackendParams) {
        self.containerName = "sah-browser-\(params.scopeKey)"
        self.settings = params.config.browser
        self.hostWorkspace = FilesystemCanonicalPath.resolve(params.workspaceDir)
        self.configHash = SandboxConfigHash.compute(config: params.config)
        self.workdir = "/home/browser"
        self.runtimeId = containerName
        self.runtimeLabel = containerName
        self.configLabel = settings.image
        self.env = nil
    }

    public func buildExecSpec(params: SandboxBuildExecSpecParams) async throws -> SandboxBackendExecSpec {
        throw SandboxBackendError.commandFailed("browser sandbox does not support shell exec")
    }

    public func runShellCommand(params: SandboxBackendCommandParams) async throws -> SandboxBackendCommandResult {
        try await ensureContainer()
        let result = try await ShellProcessRunner.run(argv: ["docker", "exec", containerName, "/bin/bash", "-c", params.script], stdin: params.stdin)
        return SandboxBackendCommandResult(stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
    }

    func ensureContainer() async throws {
        if try await DockerSandboxInspect.isRunning(containerName: containerName) {
            let label = try await DockerSandboxInspect.configHash(containerName: containerName)
            if label == configHash { return }
            _ = try await ShellProcessRunner.run(argv: ["docker", "rm", "-f", containerName])
        }
        try await DockerSandboxNetwork.ensureExists(name: settings.network)
        let runUser = DockerSandboxRunArgs.resolveRunUser(hostWorkspace: hostWorkspace)
        let runArgs = DockerSandboxRunArgs.buildBrowser(
            containerName: containerName,
            settings: settings,
            runUser: runUser,
            configHash: configHash,
            workdir: workdir
        )
        _ = try await ShellProcessRunner.run(argv: runArgs)
    }
}

public struct DockerBrowserSandboxBackendManager: SandboxBackendManager {
    public init() {}

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        let name = "sah-browser-\(params.scopeKey)"
        let running = try await DockerSandboxInspect.isRunning(containerName: name)
        let currentHash = SandboxConfigHash.compute(config: params.config)
        let labelHash = running ? try await DockerSandboxInspect.configHash(containerName: name) : nil
        let configMatches = DockerSandboxConfigMatch.matches(running: running, labelHash: labelHash, currentHash: currentHash)
        return SandboxBackendRuntimeInfo(runtimeId: name, running: running, configMatches: configMatches, runtimeLabel: name)
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        let name = "sah-browser-\(params.scopeKey)"
        _ = try await ShellProcessRunner.run(argv: ["docker", "rm", "-f", name])
    }
}

public enum DockerBrowserSandboxBackendRegistration {
    public static func register() {
        SandboxBackendRegistry.register(
            SandboxBackendRegistration(
                manifest: SandboxBackendManifests.dockerBrowser,
                factory: { params in DockerBrowserSandboxBackendHandle(params: params) },
                manager: DockerBrowserSandboxBackendManager()
            )
        )
    }
}
