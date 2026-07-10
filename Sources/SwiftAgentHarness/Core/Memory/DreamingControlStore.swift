import Foundation
import Logging

/// Persistable on/off gate for background dreaming sweeps (slash `/dreaming` + bridge).
struct DreamingControlStore: Sendable {
    static let filename = "dreaming-control.json"
    static let overrideEnvKey = "SAH_DREAMING_CONTROL_ROOT"

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
        cronExpr: String,
        memoryDirectory: URL?,
        config: MemoryConfiguration = .default
    ) -> String {
        let enabled = isEnabled()
        var lines = [
            "Dreaming: \(enabled ? "on" : "off")",
            "Cron: \(cronExpr)",
            "Control file: \(controlFileURL.path)",
        ]
        lines.append(contentsOf: DreamingReviewFormatter.statusExtras(
            config: config,
            memoryDirectory: memoryDirectory
        ))
        return lines.joined(separator: "\n")
    }
}
