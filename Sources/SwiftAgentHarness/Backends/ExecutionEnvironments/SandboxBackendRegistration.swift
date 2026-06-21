import Foundation

public struct CreateSandboxBackendParams: Sendable {
    public let sessionKey: String
    public let scopeKey: String
    public let workspaceDir: String
    public let agentWorkspaceDir: String
    public let config: SandboxConfig
    public let memoryDirectory: String?

    public init(
        sessionKey: String,
        scopeKey: String,
        workspaceDir: String,
        agentWorkspaceDir: String,
        config: SandboxConfig,
        memoryDirectory: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.scopeKey = scopeKey
        self.workspaceDir = workspaceDir
        self.agentWorkspaceDir = agentWorkspaceDir
        self.config = config
        self.memoryDirectory = memoryDirectory
    }
}

public struct SandboxBackendRuntimeInfo: Sendable, Equatable {
    public let runtimeId: String
    public let running: Bool
    public let configMatches: Bool
    public let runtimeLabel: String

    public init(runtimeId: String, running: Bool, configMatches: Bool, runtimeLabel: String) {
        self.runtimeId = runtimeId
        self.running = running
        self.configMatches = configMatches
        self.runtimeLabel = runtimeLabel
    }
}

public struct SandboxBackendDescribeRuntimeParams: Sendable {
    public let sessionKey: String
    public let scopeKey: String
    public let config: SandboxConfig

    public init(sessionKey: String, scopeKey: String, config: SandboxConfig) {
        self.sessionKey = sessionKey
        self.scopeKey = scopeKey
        self.config = config
    }
}

public struct SandboxBackendRemoveRuntimeParams: Sendable {
    public let sessionKey: String
    public let scopeKey: String
    public let config: SandboxConfig

    public init(sessionKey: String, scopeKey: String, config: SandboxConfig) {
        self.sessionKey = sessionKey
        self.scopeKey = scopeKey
        self.config = config
    }
}

public typealias SandboxBackendFactory = @Sendable (CreateSandboxBackendParams) async throws -> any SandboxBackendHandle

public protocol SandboxBackendManager: Sendable {
    func describeRuntime(params: SandboxBackendDescribeRuntimeParams) async throws -> SandboxBackendRuntimeInfo
    func removeRuntime(params: SandboxBackendRemoveRuntimeParams) async throws
}

public struct SandboxBackendRegistration: Sendable {
    public let manifest: SandboxBackendManifest
    public let factory: SandboxBackendFactory
    public let manager: any SandboxBackendManager

    public init(manifest: SandboxBackendManifest, factory: @escaping SandboxBackendFactory, manager: any SandboxBackendManager) {
        self.manifest = manifest
        self.factory = factory
        self.manager = manager
    }
}

public struct NoOpSandboxBackendManager: SandboxBackendManager {
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
