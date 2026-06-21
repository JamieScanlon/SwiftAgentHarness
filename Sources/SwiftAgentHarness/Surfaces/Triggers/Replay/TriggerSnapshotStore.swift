import Foundation

enum TriggerSnapshotStoreError: Error, Equatable {
    case notFound(String)
    case unreadable
}

struct TriggerSnapshotStore: Sendable {
    let directory: URL

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("trigger_snapshots", isDirectory: true)
    }

    func save(_ trigger: HarnessTrigger) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: trigger.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(trigger).write(to: url, options: .atomic)
    }

    func load(triggerID: String) throws -> HarnessTrigger {
        let url = fileURL(for: triggerID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TriggerSnapshotStoreError.notFound(triggerID)
        }
        guard let data = try? Data(contentsOf: url),
              let trigger = try? JSONDecoder().decode(HarnessTrigger.self, from: data) else {
            throw TriggerSnapshotStoreError.unreadable
        }
        return trigger
    }

    private func fileURL(for triggerID: String) -> URL {
        let sanitized = triggerID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(sanitized).json")
    }
}
