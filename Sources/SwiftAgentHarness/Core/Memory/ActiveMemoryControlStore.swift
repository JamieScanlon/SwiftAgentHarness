import Foundation

/// Persistable global soft gate for active-memory pre-reply recall (`/active-memory … --global`).
struct ActiveMemoryControlStore: Sendable {
    static let filename = "active-memory-control.json"
    static let overrideEnvKey = "SAH_ACTIVE_MEMORY_CONTROL_ROOT"

    let rootDirectory: URL

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else if let override = ProcessInfo.processInfo.environment[Self.overrideEnvKey],
                  !override.isEmpty {
            self.rootDirectory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.rootDirectory = MemoryConfigHome.resolve(fileManager: fileManager)
        }
    }

    var controlFileURL: URL {
        rootDirectory.appendingPathComponent(Self.filename)
    }

    /// Missing file means enabled (default on).
    func isEnabled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: controlFileURL.path),
              let data = try? Data(contentsOf: controlFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["enabled"] as? Bool
        else {
            return true
        }
        return enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = ["enabled": enabled]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try MemoryFileLock.atomicWrite(data: data, to: controlFileURL, fileManager: fm)
    }

    func statusSummary(
        config: MemoryConfiguration = .default,
        sessionEnabled: Bool? = nil
    ) -> String {
        var lines: [String] = [
            "Config activeMemoryEnabled: \(config.activeMemoryEnabled ? "on" : "off")",
            "Active memory (global soft): \(isEnabled() ? "on" : "off")",
        ]
        if let sessionEnabled {
            lines.append("Active memory (session): \(sessionEnabled ? "on" : "off")")
        }
        lines.append(contentsOf: [
            "Standing lane: \(config.activeMemoryStandingEnabled ? "on" : "off")",
            "Situational lane: \(config.activeMemorySituationalEnabled ? "on" : "off")",
            "queryMode: \(config.activeMemoryQueryMode.rawValue)",
            "promptStyle: \(config.activeMemoryPromptStyle.rawValue)",
            "maxSummaryChars: \(config.activeMemoryMaxSummaryChars)",
            "situationalTimeoutMs: \(config.activeMemorySituationalTimeoutMs)",
            "standingBudgetMs: \(config.activeMemoryStandingBudgetMs)",
            "logging: \(config.activeMemoryLogging ? "on" : "off")",
            "Control file: \(controlFileURL.path)",
        ])
        return lines.joined(separator: "\n")
    }
}
