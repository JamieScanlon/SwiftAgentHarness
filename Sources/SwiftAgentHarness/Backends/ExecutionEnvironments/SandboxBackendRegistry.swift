import Foundation

public enum SandboxBackendRegistry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var registrations: [SandboxBackendID: SandboxBackendRegistration] = [:]
    private nonisolated(unsafe) static var bootstrapped = false

    public static func register(_ registration: SandboxBackendRegistration) {
        lock.lock()
        defer { lock.unlock() }
        registerUnlocked(registration)
    }

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        registrations = [:]
        bootstrapped = false
    }

    public static func bootstrapBuiltInsIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !bootstrapped else { return }
        bootstrapped = true
        registerUnlocked(SandboxBackendRegistration(
            manifest: SandboxBackendManifests.local,
            factory: { params in LocalSandboxBackendHandle(params: params) },
            manager: LocalSandboxBackendManager()
        ))
        registerUnlocked(SandboxBackendRegistration(
            manifest: SandboxBackendManifests.docker,
            factory: { params in DockerSandboxBackendHandle(params: params) },
            manager: DockerSandboxBackendManager()
        ))
        registerUnlocked(SandboxBackendRegistration(
            manifest: SandboxBackendManifests.ssh,
            factory: { params in try SSHSandboxBackendHandle(params: params) },
            manager: SSHSandboxBackendManager()
        ))
        registerUnlocked(SandboxBackendRegistration(
            manifest: SandboxBackendManifests.dockerBrowser,
            factory: { params in DockerBrowserSandboxBackendHandle(params: params) },
            manager: DockerBrowserSandboxBackendManager()
        ))
        registerUnlocked(SandboxBackendRegistration(
            manifest: SandboxBackendManifests.openshell,
            factory: { params in try OpenShellSandboxBackendHandle(params: params) },
            manager: OpenShellSandboxBackendManager()
        ))
    }

    private static func registerUnlocked(_ registration: SandboxBackendRegistration) {
        if registrations[registration.manifest.id] != nil {
            fatalError("Duplicate sandbox backend registration: \(registration.manifest.id)")
        }
        registrations[registration.manifest.id] = registration
    }

    public static func registration(for id: SandboxBackendID) throws -> SandboxBackendRegistration {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let registration = registrations[id] else {
            throw SandboxBackendError.notRegistered(id)
        }
        return registration
    }

    public static func factory(for id: SandboxBackendID) throws -> SandboxBackendFactory {
        try registration(for: id).factory
    }

    public static func manager(for id: SandboxBackendID) throws -> any SandboxBackendManager {
        try registration(for: id).manager
    }

    public static func manifest(for id: SandboxBackendID) throws -> SandboxBackendManifest {
        try registration(for: id).manifest
    }

    public static func allManifests() -> [SandboxBackendManifest] {
        bootstrapBuiltInsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return registrations.values.map(\.manifest).sorted { $0.id < $1.id }
    }

    public static func createHandle(params: CreateSandboxBackendParams) async throws -> any SandboxBackendHandle {
        let factory = try factory(for: params.config.backend)
        return try await factory(params)
    }
}
