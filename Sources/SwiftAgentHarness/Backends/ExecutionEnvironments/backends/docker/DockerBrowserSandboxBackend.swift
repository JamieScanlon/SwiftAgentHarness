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

    init(params: CreateSandboxBackendParams) {
        self.containerName = "sah-browser-\(params.scopeKey.replacingOccurrences(of: ":", with: "-"))"
        self.settings = params.config.browser
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
        let inspect = try await ShellProcessRunner.run(argv: ["docker", "inspect", "-f", "{{.State.Running}}", containerName])
        if String(data: inspect.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            return
        }
        _ = try await ShellProcessRunner.run(argv: [
            "docker", "run", "-d", "--name", containerName,
            "--network", "sah-sandbox-browser",
            settings.image,
            "sleep", "infinity",
        ])
    }
}

public struct DockerBrowserSandboxBackendManager: SandboxBackendManager {
    public init() {}

    public func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo {
        let name = "sah-browser-\(params.scopeKey.replacingOccurrences(of: ":", with: "-"))"
        let inspect = try await ShellProcessRunner.run(argv: ["docker", "inspect", "-f", "{{.State.Running}}", name])
        let running = String(data: inspect.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        return SandboxBackendRuntimeInfo(runtimeId: name, running: running, configMatches: true, runtimeLabel: name)
    }

    public func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws {
        let name = "sah-browser-\(params.scopeKey.replacingOccurrences(of: ":", with: "-"))"
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
