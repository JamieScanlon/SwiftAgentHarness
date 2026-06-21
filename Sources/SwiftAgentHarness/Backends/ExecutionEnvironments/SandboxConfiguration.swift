import Foundation

public struct SandboxConfiguration: Sendable, Equatable, Codable {
    public var global: SandboxGlobalSettings

    public init(global: SandboxGlobalSettings = SandboxGlobalSettings()) {
        self.global = global
    }

    public static let `default` = SandboxConfiguration()
}

public enum SandboxConfigurationLoader {
    public static func load(from data: Data) throws -> SandboxConfiguration {
        try JSONDecoder().decode(SandboxConfiguration.self, from: data)
    }

    public static func load(from url: URL) throws -> SandboxConfiguration {
        try load(from: Data(contentsOf: url))
    }
}

public struct SSHOnboardingChecker: Sendable {
    public init() {}

    public func validate(settings: SSHSandboxSettings) async -> [String] {
        var issues: [String] = []
        if settings.host.isEmpty { issues.append("host is required") }
        if settings.user.isEmpty { issues.append("user is required") }
        if let identity = settings.identityFile, !FileManager.default.fileExists(atPath: identity) {
            issues.append("identity file not found: \(identity)")
        }
        let result = try? await ShellProcessRunner.run(argv: [
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-p", String(settings.port),
            "\(settings.user)@\(settings.host)", "echo", "ok",
        ])
        if result?.exitCode != 0 {
            issues.append("ssh connectivity check failed")
        }
        return issues
    }
}
