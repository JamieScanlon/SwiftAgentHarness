import Foundation
import Logging

struct TriggerSchedulerConfiguration: Sendable {
    var recurringMaxAgeMs: Int64 = 90 * 24 * 60 * 60 * 1000
    var tickIntervalSeconds: TimeInterval = 1
    var lockIdentity: String = "sah-trigger-scheduler"
}

/// Durable run-delivery queue ports (`SessionBackend.appendTaskRun` / `latestUndeliveredTaskRun` / `markTaskRunDelivered`).
public struct TriggerTaskRunPorts: Sendable {
    public var append: @Sendable (_ jobId: String, _ payload: Data, _ idempotencyKey: String?) async throws -> UUID
    public var latestUndelivered: @Sendable (_ jobId: String) async throws -> SessionHarnessTaskRunRecord?
    public var markDelivered: @Sendable (_ runId: UUID) async throws -> Void

    public init(
        append: @escaping @Sendable (_ jobId: String, _ payload: Data, _ idempotencyKey: String?) async throws -> UUID,
        latestUndelivered: @escaping @Sendable (_ jobId: String) async throws -> SessionHarnessTaskRunRecord?,
        markDelivered: @escaping @Sendable (_ runId: UUID) async throws -> Void
    ) {
        self.append = append
        self.latestUndelivered = latestUndelivered
        self.markDelivered = markDelivered
    }

    public static let disabled = TriggerTaskRunPorts(
        append: { _, _, _ in UUID() },
        latestUndelivered: { _ in nil },
        markDelivered: { _ in }
    )
}

public actor TriggerSchedulerService {
    private let store: ScheduledTaskStore
    private let deliver: @Sendable (HarnessTrigger) async throws -> TriggerActivationResult
    private let lockURL: URL
    private let config: TriggerSchedulerConfiguration
    private let taskRuns: TriggerTaskRunPorts
    private let logger: Logger
    private var tickTask: Task<Void, Never>?
    private var ownsLock = false

    init(
        store: ScheduledTaskStore,
        dispatch: TriggerDispatchService,
        lockURL: URL,
        config: TriggerSchedulerConfiguration = TriggerSchedulerConfiguration(),
        taskRuns: TriggerTaskRunPorts = .disabled,
        logger: Logger
    ) {
        self.init(
            store: store,
            deliver: { try await dispatch.ingest($0) },
            lockURL: lockURL,
            config: config,
            taskRuns: taskRuns,
            logger: logger
        )
    }

    init(
        store: ScheduledTaskStore,
        deliver: @escaping @Sendable (HarnessTrigger) async throws -> TriggerActivationResult,
        lockURL: URL,
        config: TriggerSchedulerConfiguration = TriggerSchedulerConfiguration(),
        taskRuns: TriggerTaskRunPorts = .disabled,
        logger: Logger
    ) {
        self.store = store
        self.deliver = deliver
        self.lockURL = lockURL
        self.config = config
        self.taskRuns = taskRuns
        self.logger = logger
    }

    public func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            guard let self else { return }
            await self.catchUp()
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(config.tickIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        if ownsLock {
            try? SchedulerLock.release(lockURL: lockURL, identity: config.lockIdentity)
            ownsLock = false
        }
    }

    func createTask(_ task: ScheduledTask, allowPermanent: Bool = false) throws -> ScheduledTask {
        switch ScheduledTaskCreateScanner.validateCreate(task: task, allowPermanent: allowPermanent) {
        case .failure(let error):
            throw error
        case .success:
            break
        }
        return try store.upsert(task)
    }

    func listTasks() throws -> [ScheduledTask] {
        try store.load()
    }

    func deleteTask(id: String) throws -> Bool {
        try store.delete(id: id)
    }

    func fireNow(id: String) async throws -> TriggerActivationResult {
        guard var task = try store.task(id: id) else {
            throw ScheduledTaskValidationError.invalidSchedule("task not found")
        }
        let windowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return try await fire(task: &task, missed: false, windowMs: windowMs)
    }

    /// Completes deliveries that were enqueued but undelivered before the last restart, honoring the per-kind missed-fire policy.
    func catchUp() async {
        do {
            let tasks = try store.load()
            let now = Date()
            for task in tasks {
                guard let pending = try await taskRuns.latestUndelivered(task.id) else { continue }
                guard CronRunWindow.contains(record: pending, task: task, now: now) else {
                    logger.info("scheduler_catchup_skip job=\(task.id) reason=out-of-window")
                    continue
                }
                let trigger = ScheduledTaskTriggerBuilder.makeTrigger(
                    from: task,
                    missed: true,
                    fireTimestampMs: Int64(pending.createdAt.timeIntervalSince1970 * 1000)
                )
                _ = try await deliver(trigger)
                try await taskRuns.markDelivered(pending.runId)
                logger.info("scheduler_catchup_delivered job=\(task.id) run=\(pending.runId)")
            }
        } catch {
            logger.warning("scheduler_catchup_failed error=\(String(describing: error))")
        }
    }

    private func tick() async {
        do {
            ownsLock = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: config.lockIdentity)
            guard ownsLock else { return }
            let tasks = try store.load()
            let now = Date()
            var remaining: [ScheduledTask] = []
            var changed = false
            for var task in tasks {
                if shouldAgeOut(task, now: now) {
                    changed = true
                    continue
                }
                if let fireAt = nextFireDate(for: task, now: now), fireAt <= now {
                    let windowMs = task.lastFiredAt ?? task.createdAt
                    _ = try await fire(task: &task, missed: fireAt < now.addingTimeInterval(-1), windowMs: windowMs)
                    changed = true
                    if task.recurring {
                        task.lastFiredAt = Int64(now.timeIntervalSince1970 * 1000)
                        remaining.append(task)
                    }
                } else {
                    remaining.append(task)
                }
            }
            if changed {
                try store.save(remaining)
            }
        } catch {
            logger.warning("scheduler_tick_failed error=\(String(describing: error))")
        }
    }

    private func fire(task: inout ScheduledTask, missed: Bool, windowMs: Int64) async throws -> TriggerActivationResult {
        let trigger = ScheduledTaskTriggerBuilder.makeTrigger(from: task, missed: missed)
        let runId = try await taskRuns.append(task.id, Data(task.payloadText.utf8), "\(task.id):\(windowMs)")
        let result = try await deliver(trigger)
        try await taskRuns.markDelivered(runId)
        return result
    }

    private func shouldAgeOut(_ task: ScheduledTask, now: Date) -> Bool {
        guard task.recurring, !task.permanent, config.recurringMaxAgeMs > 0 else { return false }
        let ageMs = Int64(now.timeIntervalSince1970 * 1000) - task.createdAt
        return ageMs > config.recurringMaxAgeMs
    }

    func nextFireDate(for task: ScheduledTask, now: Date) -> Date? {
        let anchorMs = task.lastFiredAt ?? task.createdAt
        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
        switch task.schedule.kind {
        case .at:
            guard let at = task.schedule.at, let date = ISO8601DateFormatter().date(from: at) else { return nil }
            if task.lastFiredAt != nil { return nil }
            return jittered(date: date, intervalMs: nil)
        case .every:
            guard let ms = task.schedule.intervalMs else { return nil }
            let base = task.lastFiredAt == nil ? now : anchor.addingTimeInterval(TimeInterval(ms) / 1000)
            return jittered(date: base, intervalMs: ms)
        case .cron:
            guard let expr = task.schedule.expr, let cron = try? CronSchedule(expression: expr) else { return nil }
            let after = task.lastFiredAt == nil ? anchor : now
            guard let next = cron.nextDate(after: after) else { return nil }
            return jittered(date: next, intervalMs: 60_000)
        }
    }

    private func jittered(date: Date, intervalMs: Int64?) -> Date {
        let maxJitter: TimeInterval = 60
        let pct = 0.10
        let span: TimeInterval
        if let intervalMs {
            span = min(TimeInterval(intervalMs) / 1000 * pct, maxJitter)
        } else {
            span = min(5, maxJitter)
        }
        let offset = Double.random(in: -span ... span)
        return date.addingTimeInterval(offset)
    }
}
