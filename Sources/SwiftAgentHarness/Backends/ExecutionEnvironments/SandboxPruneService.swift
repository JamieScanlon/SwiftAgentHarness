import Foundation

public struct SandboxPruneReport: Sendable, Equatable {
    public let removed: [String]
}

public enum SandboxPruneService {
    public static func prune(config: SandboxConfig, now: Date = Date()) async throws -> SandboxPruneReport {
        let registry = SandboxRuntimeRegistry.shared
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let idleMs = Int64(config.prune.idleHours * 3600 * 1000)
        let maxAgeMs = Int64(config.prune.maxAgeDays) * 24 * 3600 * 1000
        var removed: [String] = []
        for entry in await registry.list() {
            let idle = nowMs - entry.lastUsedAtMs
            let age = nowMs - entry.createdAtMs
            guard idle > idleMs || age > maxAgeMs else { continue }
            let manifest = try? SandboxBackendRegistry.manifest(for: entry.backendId)
            guard manifest?.capabilities.persistentRuntime == true else { continue }
            let manager = try SandboxBackendRegistry.manager(for: entry.backendId)
            try await manager.removeRuntime(params: SandboxBackendRemoveRuntimeParams(
                sessionKey: entry.sessionKey,
                scopeKey: entry.scopeKey,
                config: config
            ))
            try await registry.remove(runtimeId: entry.runtimeId)
            removed.append(entry.runtimeId)
        }
        return SandboxPruneReport(removed: removed)
    }

    public static func list() async -> [SandboxRuntimeEntry] {
        await SandboxRuntimeRegistry.shared.list()
    }
}
