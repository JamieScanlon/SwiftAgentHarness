import Foundation
import Logging

/// Installer-only permanent cron task for nightly dreaming consolidation.
enum MemoryDreamingCronInstaller {
    static let taskID = MemoryDreamingBridge.dreamTaskID

    /// Sync install via the task store (composition-root path; `resolve` is non-async).
    /// When `dreamingEnabled` is false, removes any existing permanent dream task and returns nil.
    @discardableResult
    static func ensureInstalled(
        store: ScheduledTaskStore,
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        logger: Logger? = nil
    ) throws -> ScheduledTask? {
        guard config.dreamingEnabled else {
            if try store.delete(id: taskID) {
                logger?.info("[Dreaming] removed permanent cron task id=\(taskID) (dreamingEnabled=false)")
            } else {
                logger?.info("[Dreaming] cron install skipped — dreamingEnabled=false")
            }
            return nil
        }
        let task = makeTask(config: config, existing: try store.task(id: taskID))
        switch ScheduledTaskCreateScanner.validateCreate(task: task, allowPermanent: true) {
        case .failure(let error):
            throw error
        case .success:
            break
        }
        let saved = try store.upsert(task)
        logger?.info("[Dreaming] installed permanent cron task id=\(taskID) expr=\(config.dreamingCron)")
        return saved
    }

    /// Async install via the scheduler actor (tests / runtime helpers).
    /// When `dreamingEnabled` is false, removes any existing permanent dream task and returns nil.
    @discardableResult
    static func ensureInstalled(
        scheduler: TriggerSchedulerService,
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        logger: Logger? = nil
    ) async throws -> ScheduledTask? {
        guard config.dreamingEnabled else {
            if try await scheduler.deleteTask(id: taskID) {
                logger?.info("[Dreaming] removed permanent cron task id=\(taskID) (dreamingEnabled=false)")
            } else {
                logger?.info("[Dreaming] cron install skipped — dreamingEnabled=false")
            }
            return nil
        }
        let existing = try await scheduler.listTasks().first { $0.id == taskID }
        let task = makeTask(config: config, existing: existing)
        let saved = try await scheduler.createTask(task, allowPermanent: true)
        logger?.info("[Dreaming] installed permanent cron task id=\(taskID) expr=\(config.dreamingCron)")
        return saved
    }

    static func makeTask(config: MemoryConfiguration, existing: ScheduledTask?) -> ScheduledTask {
        let expr = config.dreamingCron
        var task = existing ?? ScheduledTask(
            id: taskID,
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .systemEvent,
            payloadText: MemoryDreamingBridge.dreamPayloadText,
            delivery: .none,
            recurring: true,
            permanent: true,
            durable: true,
            trust: .system,
            title: "Memory dreaming consolidation"
        )
        task.schedule = ScheduledTaskSchedule(kind: .cron, expr: expr)
        task.payloadKind = .systemEvent
        task.payloadText = MemoryDreamingBridge.dreamPayloadText
        task.recurring = true
        task.permanent = true
        task.trust = .system
        task.title = "Memory dreaming consolidation"
        return task
    }
}
