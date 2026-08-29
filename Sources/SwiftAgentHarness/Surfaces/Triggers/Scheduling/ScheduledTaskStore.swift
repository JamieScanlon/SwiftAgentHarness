import Foundation

enum ScheduledTaskStoreError: Error, Equatable {
    /// The task file exists and is non-empty but decodes as neither the envelope nor the legacy
    /// bare-array shape. Never recovered by truncation — that would delete the user's schedule.
    case corruptTaskFile(path: String)
}

/// What one scheduler tick changed: fire bookkeeping and removals.
///
/// Applied as a **delta** against the current file contents rather than as a wholesale rewrite, so a
/// registration that lands between the tick's read and its commit is not silently erased.
struct ScheduledTaskTickResult: Sendable, Equatable {
    /// Task id → new `lastFiredAt`.
    var firedAt: [String: Int64] = [:]
    /// Completed one-shots and aged-out recurring tasks.
    var removedIDs: Set<String> = []

    var isEmpty: Bool { firedAt.isEmpty && removedIDs.isEmpty }
}

/// Persistence for scheduled tasks. **Not** a create path.
///
/// `upsert` accepts only a ``ValidatedScheduledTask``, which cannot be constructed outside
/// ``ValidatedScheduledTask/validate(spec:authority:policy:existing:now:)``. That is what makes the
/// registration validator a chokepoint rather than a convention: there is no signature here that
/// accepts a caller-constructed `ScheduledTask`. `applyTickResults` takes a delta of ids and
/// timestamps, not rows, so it cannot introduce one either.
struct ScheduledTaskStore: Sendable {
    private static let maxTombstones = 256

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Reads

    func load() throws -> [ScheduledTask] {
        lock.lock()
        defer { lock.unlock() }
        return try readEnvelopeUnlocked().tasks
    }

    func task(id: String) throws -> ScheduledTask? {
        try load().first { $0.id == id }
    }

    /// Whether an installer-provided entry with this id was deleted by the user. The installer's
    /// write-if-missing pass consults this so a deletion survives reinstalls.
    func isTombstoned(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try readEnvelopeUnlocked().deletedSystemTaskIDs?.contains(id) ?? false
    }

    // MARK: - Writes

    /// The only create/update path.
    @discardableResult
    func upsert(_ validated: ValidatedScheduledTask) throws -> ScheduledTask {
        lock.lock()
        defer { lock.unlock() }
        let task = validated.task
        var envelope = try readEnvelopeUnlocked()
        if let idx = envelope.tasks.firstIndex(where: { $0.id == task.id }) {
            envelope.tasks[idx] = task
        } else {
            envelope.tasks.append(task)
        }
        // Re-registering an id the user had deleted is an explicit act; clear its tombstone so the
        // row behaves normally from here on.
        envelope.deletedSystemTaskIDs?.removeAll(where: { $0 == task.id })
        try writeEnvelopeUnlocked(envelope)
        return task
    }

    @discardableResult
    func delete(id: String, tombstoneSystemEntry: Bool = false) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try readEnvelopeUnlocked()
        let before = envelope.tasks.count
        envelope.tasks.removeAll { $0.id == id }
        let removed = envelope.tasks.count != before
        guard removed || tombstoneSystemEntry else { return false }
        if tombstoneSystemEntry {
            var tombstones = envelope.deletedSystemTaskIDs ?? []
            if !tombstones.contains(id) { tombstones.append(id) }
            if tombstones.count > Self.maxTombstones {
                tombstones.removeFirst(tombstones.count - Self.maxTombstones)
            }
            envelope.deletedSystemTaskIDs = tombstones
        }
        try writeEnvelopeUnlocked(envelope)
        return removed
    }

    /// Apply one tick's fire bookkeeping and removals.
    ///
    /// Re-reads under the lock and mutates only the rows the tick touched, so concurrent
    /// registrations survive. Never introduces a row.
    func applyTickResults(_ result: ScheduledTaskTickResult) throws {
        guard !result.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try readEnvelopeUnlocked()
        envelope.tasks.removeAll { result.removedIDs.contains($0.id) }
        for index in envelope.tasks.indices {
            if let firedAt = result.firedAt[envelope.tasks[index].id] {
                envelope.tasks[index].lastFiredAt = firedAt
            }
        }
        try writeEnvelopeUnlocked(envelope)
    }

    // MARK: - Envelope IO (callers must hold `lock`)

    private func readEnvelopeUnlocked() throws -> ScheduledTaskFileEnvelope {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ScheduledTaskFileEnvelope(tasks: [])
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return ScheduledTaskFileEnvelope(tasks: []) }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ScheduledTaskFileEnvelope.self, from: data) {
            return envelope
        }
        // Legacy bare-array format.
        if let rows = try? decoder.decode([FailableScheduledTaskRow].self, from: data) {
            return ScheduledTaskFileEnvelope(tasks: rows.compactMap(\.value))
        }
        // A non-empty file that decodes as neither shape is corrupt at the file level. Fail loudly
        // rather than returning an empty envelope: the caller would write that back and destroy
        // every task *and* every tombstone — which is also the one path that resurrects a
        // user-deleted installer entry.
        throw ScheduledTaskStoreError.corruptTaskFile(path: fileURL.path)
    }

    private func writeEnvelopeUnlocked(_ envelope: ScheduledTaskFileEnvelope) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// One row, decoded tolerantly.
///
/// Without this, a single malformed task fails the whole array decode, `readEnvelopeUnlocked` falls
/// through to an empty envelope, and the next write persists it — destroying every task *and* every
/// tombstone, which is also the one path that resurrects a user-deleted installer entry.
private struct FailableScheduledTaskRow: Decodable {
    let value: ScheduledTask?

    init(from decoder: any Decoder) throws {
        value = try? ScheduledTask(from: decoder)
    }
}

private struct ScheduledTaskFileEnvelope: Codable {
    var tasks: [ScheduledTask]
    /// Optional so files written by older builds decode unchanged.
    var deletedSystemTaskIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case tasks
        case deletedSystemTaskIDs
    }

    init(tasks: [ScheduledTask], deletedSystemTaskIDs: [String]? = nil) {
        self.tasks = tasks
        self.deletedSystemTaskIDs = deletedSystemTaskIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([FailableScheduledTaskRow].self, forKey: .tasks) ?? []
        self.tasks = rows.compactMap(\.value)
        self.deletedSystemTaskIDs = try container.decodeIfPresent([String].self, forKey: .deletedSystemTaskIDs)
    }
}
