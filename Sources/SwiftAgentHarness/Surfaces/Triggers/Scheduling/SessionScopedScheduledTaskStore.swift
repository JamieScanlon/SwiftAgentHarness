import Foundation

/// In-memory home for `durable: false` scheduled tasks.
///
/// "Remind me in five minutes" should not accumulate in the persistent store forever. A
/// session-scoped task lives here, is never serialized, and dies with the process — persistence is
/// the property that turns a bad registration from a bug into a foothold, so it is the property to
/// ration most tightly (`harness-template/surfaces/triggers/scheduling.md` §Durability).
///
/// Same chokepoint as the durable store: `upsert` accepts only a ``ValidatedScheduledTask``.
final class SessionScopedScheduledTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: ScheduledTask] = [:]

    init() {}

    func all() -> [ScheduledTask] {
        lock.lock()
        defer { lock.unlock() }
        // Stable order so `schedule_list` output does not shuffle between calls.
        return tasks.values.sorted { $0.id < $1.id }
    }

    func task(id: String) -> ScheduledTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]
    }

    @discardableResult
    func upsert(_ validated: ValidatedScheduledTask) -> ScheduledTask {
        lock.lock()
        defer { lock.unlock() }
        let task = validated.task
        tasks[task.id] = task
        return task
    }

    @discardableResult
    func delete(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: id) != nil
    }

    func applyTickResults(_ result: ScheduledTaskTickResult) {
        guard !result.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in result.removedIDs {
            tasks.removeValue(forKey: id)
        }
        for (id, firedAt) in result.firedAt {
            tasks[id]?.lastFiredAt = firedAt
        }
    }
}
