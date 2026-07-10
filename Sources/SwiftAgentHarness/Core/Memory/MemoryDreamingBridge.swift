import Foundation
import Logging

/// Enumerates project memory directories and runs dreaming sweeps when enabled.
struct MemoryDreamingBridge: Sendable {
    static let dreamTaskID = "dream"
    static let dreamPayloadText = "dream"

    let config: MemoryConfiguration
    let controlStore: DreamingControlStore
    let projectsRoot: URL
    let logger: Logger?
    let now: @Sendable () -> Date

    init(
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        controlStore: DreamingControlStore = DreamingControlStore(),
        projectsRoot: URL? = nil,
        logger: Logger? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.controlStore = controlStore
        self.projectsRoot = projectsRoot
            ?? MemoryConfigHome.resolve().appendingPathComponent("projects", isDirectory: true)
        self.logger = logger
        self.now = now
    }

    /// Returns true when a cron trigger should be handled by this bridge instead of LLM dispatch.
    static func isDreamTrigger(_ trigger: HarnessTrigger) -> Bool {
        if trigger.sourceMetadata["cronJobId"] == dreamTaskID { return true }
        let payload = trigger.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return payload == dreamPayloadText || payload == "[missed] \(dreamPayloadText)"
    }

    @discardableResult
    func runDueSweeps(rollback: Bool = false) async throws -> Int {
        guard config.dreamingEnabled else {
            logger?.info("[Dreaming] sweeps skipped — dreamingEnabled=false in config")
            return 0
        }
        guard controlStore.isEnabled() else {
            logger?.info("[Dreaming] sweeps skipped — dreaming is off")
            return 0
        }
        let dirs = discoverMemoryDirectories()
        guard !dirs.isEmpty else {
            logger?.info("[Dreaming] no project memory directories under \(projectsRoot.path)")
            return 0
        }
        let scheduler = DreamingConsolidationScheduler(config: config, logger: logger, now: now)
        var swept = 0
        for dir in dirs {
            do {
                try await scheduler.runSweep(memoryDirectory: dir, rollback: rollback)
                swept += 1
            } catch {
                logger?.error("[Dreaming] sweep failed for \(dir.path): \(error.localizedDescription)")
            }
        }
        logger?.info("[Dreaming] swept \(swept)/\(dirs.count) memory director\(dirs.count == 1 ? "y" : "ies")")
        return swept
    }

    func discoverMemoryDirectories() -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsRoot.path),
              let projects = try? fm.contentsOfDirectory(
                  at: projectsRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return []
        }
        var results: [URL] = []
        for project in projects {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: project.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let memoryDir = project.appendingPathComponent("memory", isDirectory: true)
            guard fm.fileExists(atPath: memoryDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard directoryLooksLikeMemory(memoryDir) else { continue }
            results.append(memoryDir)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func directoryLooksLikeMemory(_ memoryDir: URL) -> Bool {
        let fm = FileManager.default
        let index = memoryDir.appendingPathComponent("MEMORY.md")
        if fm.fileExists(atPath: index.path) { return true }
        let dreams = memoryDir.appendingPathComponent(".dreams", isDirectory: true)
        if fm.fileExists(atPath: dreams.path) { return true }
        guard let contents = try? fm.contentsOfDirectory(at: memoryDir, includingPropertiesForKeys: nil) else {
            return false
        }
        return contents.contains { $0.pathExtension.lowercased() == "md" }
    }
}
