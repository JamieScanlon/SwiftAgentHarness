import Foundation

struct ScheduledTaskStore: Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> [ScheduledTask] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if let tasks = try? decoder.decode([ScheduledTask].self, from: data) {
            return tasks
        }
        if let envelope = try? decoder.decode(ScheduledTaskFileEnvelope.self, from: data) {
            return envelope.tasks
        }
        return []
    }

    func save(_ tasks: [ScheduledTask]) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = ScheduledTaskFileEnvelope(tasks: tasks)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ task: ScheduledTask) throws -> ScheduledTask {
        var tasks = try load()
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
        try save(tasks)
        return task
    }

    func delete(id: String) throws -> Bool {
        var tasks = try load()
        let before = tasks.count
        tasks.removeAll { $0.id == id }
        guard tasks.count != before else { return false }
        try save(tasks)
        return true
    }

    func task(id: String) throws -> ScheduledTask? {
        try load().first { $0.id == id }
    }
}

private struct ScheduledTaskFileEnvelope: Codable {
    var tasks: [ScheduledTask]
}
