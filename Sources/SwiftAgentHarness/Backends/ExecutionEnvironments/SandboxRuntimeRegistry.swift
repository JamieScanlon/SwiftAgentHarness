import Foundation

public struct SandboxRuntimeEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: String { runtimeId }
    public let runtimeId: String
    public let sessionKey: String
    public let scopeKey: String
    public let backendId: SandboxBackendID
    public var createdAtMs: Int64
    public var lastUsedAtMs: Int64
    public let configHash: String
    public let runtimeLabel: String

    public init(
        runtimeId: String,
        sessionKey: String,
        scopeKey: String,
        backendId: SandboxBackendID,
        createdAtMs: Int64,
        lastUsedAtMs: Int64,
        configHash: String,
        runtimeLabel: String
    ) {
        self.runtimeId = runtimeId
        self.sessionKey = sessionKey
        self.scopeKey = scopeKey
        self.backendId = backendId
        self.createdAtMs = createdAtMs
        self.lastUsedAtMs = lastUsedAtMs
        self.configHash = configHash
        self.runtimeLabel = runtimeLabel
    }
}

public struct SandboxRuntimeRegistrySnapshot: Sendable, Equatable, Codable {
    public var entries: [SandboxRuntimeEntry]

    public init(entries: [SandboxRuntimeEntry] = []) {
        self.entries = entries
    }
}

public actor SandboxRuntimeRegistry {
    public static let shared = SandboxRuntimeRegistry()

    private var entries: [SandboxRuntimeEntry] = []
    private let store: SandboxRuntimeRegistryStore

    public init(store: SandboxRuntimeRegistryStore = SandboxRuntimeRegistryStore()) {
        self.store = store
        if let loaded = try? store.load() {
            entries = loaded.entries
        }
    }

    public func list() -> [SandboxRuntimeEntry] {
        entries.sorted { $0.lastUsedAtMs > $1.lastUsedAtMs }
    }

    public func upsert(_ entry: SandboxRuntimeEntry) async throws {
        if let idx = entries.firstIndex(where: { $0.runtimeId == entry.runtimeId }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        try await persist()
    }

    public func touch(runtimeId: String) async throws {
        guard let idx = entries.firstIndex(where: { $0.runtimeId == runtimeId }) else { return }
        entries[idx].lastUsedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await persist()
    }

    public func remove(runtimeId: String) async throws {
        entries.removeAll { $0.runtimeId == runtimeId }
        try await persist()
    }

    public func recreate(runtimeId: String, config: SandboxConfig) async throws {
        guard let entry = entries.first(where: { $0.runtimeId == runtimeId }) else {
            throw SandboxBackendError.runtimeNotFound(runtimeId)
        }
        let manager = try SandboxBackendRegistry.manager(for: entry.backendId)
        try await manager.removeRuntime(params: SandboxBackendRemoveRuntimeParams(
            sessionKey: entry.sessionKey,
            scopeKey: entry.scopeKey,
            config: config
        ))
        try await remove(runtimeId: runtimeId)
    }

    private func persist() async throws {
        try await store.save(SandboxRuntimeRegistrySnapshot(entries: entries))
    }

    public func resetForTesting() {
        entries = []
    }
}

public struct SandboxRuntimeRegistryStore: Sendable {
    public let registryURL: URL

    public init(registryURL: URL? = nil) {
        if let registryURL {
            self.registryURL = registryURL
        } else {
            self.registryURL = HarnessHostPaths.sandboxRegistryURL()
        }
    }

    public func load() throws -> SandboxRuntimeRegistrySnapshot {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return SandboxRuntimeRegistrySnapshot()
        }
        let data = try Data(contentsOf: registryURL)
        return try JSONDecoder().decode(SandboxRuntimeRegistrySnapshot.self, from: data)
    }

    public func save(_ snapshot: SandboxRuntimeRegistrySnapshot) async throws {
        let lockURL = registryURL.deletingLastPathComponent().appendingPathComponent("sandbox-registry.lock")
        try SessionWriteLock.withLock(lockURL: lockURL) {
            let dir = registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            let temp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)-sandbox-registry.json")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: registryURL.path) {
                _ = try FileManager.default.replaceItemAt(registryURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: registryURL)
            }
        }
    }
}
