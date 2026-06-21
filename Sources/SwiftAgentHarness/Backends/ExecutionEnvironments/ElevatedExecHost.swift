import Foundation

public enum ElevatedExecPath: String, Sendable, Codable, Equatable {
    case gateway
    case node
}

public enum ElevatedMode: String, Sendable, Codable, Equatable {
    case off
    case on
    case ask
    case full
}

public struct ExecSenderIdentity: Sendable, Equatable {
    public let surface: String
    public let senderID: String

    public init(surface: String, senderID: String) {
        self.surface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.senderID = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let cliDefault = ExecSenderIdentity(surface: "cli", senderID: "*")
}

public struct ElevatedAllowlist: Sendable, Equatable {
    public var allowFrom: [String: Set<String>]

    public init(allowFrom: [String: Set<String>] = [:]) {
        self.allowFrom = Dictionary(
            uniqueKeysWithValues: allowFrom.map { key, value in
                (key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), value)
            }
        )
    }

    public static let cliDefault = ElevatedAllowlist(allowFrom: ["cli": ["*"]])
}

public enum ElevatedSenderResolver {
    public static func isAllowed(identity: ExecSenderIdentity, allowlist: ElevatedAllowlist) -> Bool {
        let effective = allowlist.allowFrom.isEmpty ? ElevatedAllowlist.cliDefault.allowFrom : allowlist.allowFrom
        guard let allowed = effective[identity.surface] else { return false }
        if allowed.contains("*") { return true }
        return allowed.contains(identity.senderID)
    }
}

public struct ElevatedExecContext: Sendable {
    public let mode: ElevatedMode
    public let escapePath: ElevatedExecPath
    public let senderAllowed: Bool

    public init(mode: ElevatedMode, escapePath: ElevatedExecPath = .gateway, senderAllowed: Bool) {
        self.mode = mode
        self.escapePath = escapePath
        self.senderAllowed = senderAllowed
    }

    public var isActive: Bool {
        senderAllowed && mode != .off
    }
}

public enum ElevatedExecHost {
    public static func requiresExecApproval(mode: ElevatedMode) -> Bool {
        switch mode {
        case .off, .full:
            return false
        case .on, .ask:
            return true
        }
    }

    public static func run(
        context: ElevatedExecContext,
        params: SandboxBuildExecSpecParams,
        execApprovalGranted: Bool = false
    ) async throws -> ExecSupervisorResult {
        guard context.isActive else {
            throw SandboxBackendError.commandFailed("elevated mode not active")
        }
        if requiresExecApproval(mode: context.mode), !execApprovalGranted {
            throw SandboxBackendError.commandFailed("elevated exec requires approval")
        }
        switch context.escapePath {
        case .gateway:
            let argv = ["/bin/bash", "-c", params.command]
            let result = try await ShellProcessRunner.runSupervised(argv: argv, env: params.env, cwd: params.workdir)
            return ExecSupervisorResult(
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: String(decoding: result.stderr, as: UTF8.self),
                exitCode: result.exitCode,
                timedOut: false,
                backgroundTaskID: nil
            )
        case .node:
            throw SandboxBackendError.commandFailed("node escape path not configured")
        }
    }
}
