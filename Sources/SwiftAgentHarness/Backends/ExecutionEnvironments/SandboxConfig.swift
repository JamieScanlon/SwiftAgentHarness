import Foundation

public enum SandboxMode: String, Sendable, Codable, Equatable {
    case nonMain = "non-main"
    case all
}

public enum SandboxScope: String, Sendable, Codable, Equatable {
    case agent
    case session
    case shared
}

public struct DockerSandboxSettings: Sendable, Equatable, Codable {
    public var image: String
    public var workdir: String
    public var network: String
    public var extraBinds: [String]
    public var pidsLimit: Int
    public var memoryLimit: String
    public var cpus: Double

    public init(
        image: String = "sah-sandbox:bookworm-slim",
        workdir: String = "/workspace",
        network: String = "none",
        extraBinds: [String] = [],
        pidsLimit: Int = 512,
        memoryLimit: String = "4g",
        cpus: Double = 2.0
    ) {
        self.image = image
        self.workdir = workdir
        self.network = network
        self.extraBinds = extraBinds
        self.pidsLimit = pidsLimit
        self.memoryLimit = memoryLimit
        self.cpus = cpus
    }
}

public struct SSHSandboxSettings: Sendable, Equatable, Codable {
    public var host: String
    public var port: Int
    public var user: String
    public var identityFile: String?

    public init(host: String, port: Int = 22, user: String, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }
}

public struct BrowserSandboxSettings: Sendable, Equatable, Codable {
    public var image: String
    public var network: String
    public var pidsLimit: Int
    public var memoryLimit: String
    public var cpus: Double
    public var allowHostControl: Bool
    public var cdpSourceRange: String?

    public init(
        image: String = "sah-sandbox-browser:bookworm-slim",
        network: String = "sah-sandbox-browser",
        pidsLimit: Int = 512,
        memoryLimit: String = "4g",
        cpus: Double = 2.0,
        allowHostControl: Bool = false,
        cdpSourceRange: String? = nil
    ) {
        self.image = image
        self.network = network
        self.pidsLimit = pidsLimit
        self.memoryLimit = memoryLimit
        self.cpus = cpus
        self.allowHostControl = allowHostControl
        self.cdpSourceRange = cdpSourceRange
    }
}

public struct SandboxPruneSettings: Sendable, Equatable, Codable {
    public var idleHours: Double
    public var maxAgeDays: Int

    public init(idleHours: Double = 24, maxAgeDays: Int = 7) {
        self.idleHours = idleHours
        self.maxAgeDays = maxAgeDays
    }
}

public struct SandboxGlobalSettings: Sendable, Equatable, Codable {
    public static let defaultAssistantBlockingBudgetSeconds: TimeInterval = 120

    public var mode: SandboxMode
    public var scope: SandboxScope
    public var backend: SandboxBackendID
    public var enabled: Bool
    public var assistantBlockingBudgetSeconds: TimeInterval
    public var docker: DockerSandboxSettings
    public var ssh: SSHSandboxSettings?
    public var openshell: OpenShellSandboxSettings?
    public var browser: BrowserSandboxSettings
    public var prune: SandboxPruneSettings

    public init(
        mode: SandboxMode = .nonMain,
        scope: SandboxScope = .agent,
        backend: SandboxBackendID = "local",
        enabled: Bool = false,
        assistantBlockingBudgetSeconds: TimeInterval = Self.defaultAssistantBlockingBudgetSeconds,
        docker: DockerSandboxSettings = DockerSandboxSettings(),
        ssh: SSHSandboxSettings? = nil,
        openshell: OpenShellSandboxSettings? = nil,
        browser: BrowserSandboxSettings = BrowserSandboxSettings(),
        prune: SandboxPruneSettings = SandboxPruneSettings()
    ) {
        self.mode = mode
        self.scope = scope
        self.backend = backend
        self.enabled = enabled
        self.assistantBlockingBudgetSeconds = max(1, assistantBlockingBudgetSeconds)
        self.docker = docker
        self.ssh = ssh
        self.openshell = openshell
        self.browser = browser
        self.prune = prune
    }
}

public struct SandboxConfig: Sendable, Equatable {
    public let mode: SandboxMode
    public let scope: SandboxScope
    public let backend: SandboxBackendID
    /// When `true`, the configured persistent/remote backend is used; when `false`, resolution falls back to the `local` backend.
    /// Does not control Seatbelt/bwrap wrapping on the local backend — non-elevated local exec is always wrapped when tooling exists.
    public let sandboxingActive: Bool
    public let assistantBlockingBudgetSeconds: TimeInterval
    public let docker: DockerSandboxSettings
    public let ssh: SSHSandboxSettings?
    public let openshell: OpenShellSandboxSettings?
    public let browser: BrowserSandboxSettings
    public let prune: SandboxPruneSettings

    public init(
        mode: SandboxMode,
        scope: SandboxScope,
        backend: SandboxBackendID,
        sandboxingActive: Bool,
        assistantBlockingBudgetSeconds: TimeInterval = SandboxGlobalSettings.defaultAssistantBlockingBudgetSeconds,
        docker: DockerSandboxSettings = DockerSandboxSettings(),
        ssh: SSHSandboxSettings? = nil,
        openshell: OpenShellSandboxSettings? = nil,
        browser: BrowserSandboxSettings = BrowserSandboxSettings(),
        prune: SandboxPruneSettings = SandboxPruneSettings()
    ) {
        self.mode = mode
        self.scope = scope
        self.backend = backend
        self.sandboxingActive = sandboxingActive
        self.assistantBlockingBudgetSeconds = max(1, assistantBlockingBudgetSeconds)
        self.docker = docker
        self.ssh = ssh
        self.openshell = openshell
        self.browser = browser
        self.prune = prune
    }
}
