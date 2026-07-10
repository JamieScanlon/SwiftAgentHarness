import Foundation
import Logging

/// Installer-only permanent cron task for nightly dreaming consolidation.
enum MemoryDreamingCronInstaller {
    static let taskID = MemoryDreamingBridge.dreamTaskID

    /// Sync install via the task store (composition-root path; `resolve` is non-async).
    @discardableResult
    static func ensureInstalled(
        store: ScheduledTaskStore,
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        logger: Logger? = nil
    ) throws -> ScheduledTask {
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
    @discardableResult
    static func ensureInstalled(
        scheduler: TriggerSchedulerService,
        config: MemoryConfiguration = MemoryConfigurationLoader.loadFromPromptConfigBundle(),
        logger: Logger? = nil
    ) async throws -> ScheduledTask {
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
