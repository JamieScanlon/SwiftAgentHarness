import Foundation

public enum SandboxWorkspaceModel: String, Sendable, Codable, Equatable {
    case hostCanonical = "host-canonical"
    case remoteCanonical = "remote-canonical"
    case mirror
}

public struct SandboxBackendManifest: Sendable, Equatable, Codable {
    public let id: SandboxBackendID
    public let label: String
    public let workspaceModel: SandboxWorkspaceModel
    public let capabilities: SandboxBackendCapabilities
    public let adapterID: String
    public let hostTools: [String]
    public let remoteTools: [String]

    public init(
        id: SandboxBackendID,
        label: String,
        workspaceModel: SandboxWorkspaceModel,
        capabilities: SandboxBackendCapabilities,
        adapterID: String? = nil,
        hostTools: [String] = [],
        remoteTools: [String] = []
    ) {
        self.id = id
        self.label = label
        self.workspaceModel = workspaceModel
        self.capabilities = capabilities
        self.adapterID = adapterID ?? "tool-env.\(id).default"
        self.hostTools = hostTools
        self.remoteTools = remoteTools
    }
}

public enum SandboxBackendManifests {
    public static let local = SandboxBackendManifest(
        id: "local",
        label: "Local host",
        workspaceModel: .hostCanonical,
        capabilities: SandboxBackendCapabilities(browser: false, bindMounts: false, persistentRuntime: false),
        adapterID: "tool-env.local.sandbox"
    )

    public static let docker = SandboxBackendManifest(
        id: "docker",
        label: "Docker",
        workspaceModel: .hostCanonical,
        capabilities: SandboxBackendCapabilities(browser: false, bindMounts: true, persistentRuntime: true),
        adapterID: "tool-env.docker.default"
    )

    public static let ssh = SandboxBackendManifest(
        id: "ssh",
        label: "SSH",
        workspaceModel: .remoteCanonical,
        capabilities: SandboxBackendCapabilities(browser: false, bindMounts: false, persistentRuntime: true),
        adapterID: "tool-env.ssh.default",
        hostTools: ["rsync"],
        remoteTools: ["rsync"]
    )

    public static let dockerBrowser = SandboxBackendManifest(
        id: "docker-browser",
        label: "Docker Browser",
        workspaceModel: .hostCanonical,
        capabilities: SandboxBackendCapabilities(browser: true, bindMounts: false, persistentRuntime: true),
        adapterID: "tool-env.docker.browser"
    )

    public static let openshell = SandboxBackendManifest(
        id: "openshell",
        label: "OpenShell",
        workspaceModel: .mirror,
        capabilities: SandboxBackendCapabilities(browser: false, bindMounts: false, persistentRuntime: true),
        adapterID: "tool-env.openshell.default",
        hostTools: ["openshell"]
    )

    public static let all: [SandboxBackendManifest] = [local, docker, ssh, dockerBrowser, openshell]

    public static func manifest(for backendID: SandboxBackendID) -> SandboxBackendManifest? {
        all.first { $0.id == backendID }
    }

    public static func manifest(forAdapterID adapterID: String) -> SandboxBackendManifest? {
        all.first { $0.adapterID == adapterID }
    }
}
