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
    private let sessionStore: SessionScopedScheduledTaskStore
    private let deliver: @Sendable (HarnessTrigger) async throws -> TriggerActivationResult
    private let lockURL: URL
    private let config: TriggerSchedulerConfiguration
    private let taskRuns: TriggerTaskRunPorts
    private let logger: Logger
    private var tickTask: Task<Void, Never>?
    private var ownsLock = false

    init(
        store: ScheduledTaskStore,
        sessionStore: SessionScopedScheduledTaskStore = SessionScopedScheduledTaskStore(),
        dispatch: TriggerDispatchService,
        lockURL: URL,
        config: TriggerSchedulerConfiguration = TriggerSchedulerConfiguration(),
        taskRuns: TriggerTaskRunPorts = .disabled,
        logger: Logger
    ) {
        self.init(
            store: store,
            sessionStore: sessionStore,
            deliver: { try await dispatch.ingest($0) },
            lockURL: lockURL,
            config: config,
            taskRuns: taskRuns,
            logger: logger
        )
    }

    init(
        store: ScheduledTaskStore,
        sessionStore: SessionScopedScheduledTaskStore = SessionScopedScheduledTaskStore(),
        deliver: @escaping @Sendable (HarnessTrigger) async throws -> TriggerActivationResult,
        lockURL: URL,
        config: TriggerSchedulerConfiguration = TriggerSchedulerConfiguration(),
        taskRuns: TriggerTaskRunPorts = .disabled,
        logger: Logger
    ) {
        self.store = store
        self.sessionStore = sessionStore
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

    // Create / update / delete live on `TriggerRegistrationService`, which is the one path that runs
    // validation, the content scan, trust clamping, and creator stamping. The scheduler reads and
    // fires; it does not register.

    /// Durable rows plus this process's session-scoped ones. Both fire; only the first persists.
    func listTasks() throws -> [ScheduledTask] {
        try store.load() + sessionStore.all()
    }

    func fireNow(id: String) async throws -> TriggerActivationResult {
        guard var task = try store.task(id: id) ?? sessionStore.task(id: id) else {
            throw ScheduledTaskValidationError.invalidSchedule("task not found")
        }
        let windowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return try await fire(task: &task, missed: false, windowMs: windowMs)
    }

    /// Completes deliveries that were enqueued but undelivered before the last restart, honoring the per-kind missed-fire policy.
    func catchUp() async {
        do {
            let tasks = try listTasks()
            let now = Date()
            for task in tasks {
                guard let pending = try await taskRuns.latestUndelivered(task.id) else { continue }
                guard CronRunWindow.contains(record: pending, task: task, now: now) else {
                    logger.info("scheduler_catchup_skip job=\(task.id) reason=out-of-window")
                    continue
                }
                guard task.enabled else {
                    // Drain rather than skip: leaving the run undelivered means it is replayed
                    // whenever the task is resumed, delivering a `[missed]` fire for a window that
                    // may be months past.
                    try await taskRuns.markDelivered(pending.runId)
                    logger.info("scheduler_catchup_drained job=\(task.id) reason=paused")
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
            let tasks = try listTasks()
            let now = Date()
            // A delta, not a replacement set: firing is `await`ed, so a registration can land
            // between this read and the commit below. Rewriting the whole file would erase it.
            var result = ScheduledTaskTickResult()
            for var task in tasks {
                // Pause first: an explicitly paused task is the clearest possible evidence the user
                // has *not* forgotten it, and age-out exists to collect forgotten ones. Checking
                // age-out first would silently delete a paused task at 90 days.
                guard task.enabled else { continue }
                if shouldAgeOut(task, now: now) {
                    result.removedIDs.insert(task.id)
                    continue
                }
                if let fireAt = nextFireDate(for: task, now: now), fireAt <= now {
                    let windowMs = task.lastFiredAt ?? task.createdAt
                    do {
                        _ = try await fire(task: &task, missed: fireAt < now.addingTimeInterval(-1), windowMs: windowMs)
                    } catch {
                        // Contain the failure to this task. Letting it escape would discard the
                        // whole delta, so tasks already delivered this tick would lose their
                        // `lastFiredAt` bump and fire again on the next pass.
                        logger.warning("scheduler_fire_failed job=\(task.id) error=\(String(describing: error))")
                        continue
                    }
                    if task.recurring {
                        result.firedAt[task.id] = Int64(now.timeIntervalSince1970 * 1000)
                    } else {
                        result.removedIDs.insert(task.id)
                    }
                }
            }
            // Infallible store first: a durable-store write failure must not strand the
            // session store's bookkeeping and re-fire its one-shots on every tick.
            sessionStore.applyTickResults(result)
            try store.applyTickResults(result)
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
            let zone = task.resolvedTimeZone
            guard let next = cron.nextDate(after: after, in: zone) else { return nil }
            // Daylight-saving fall-back: a pinned-hour job runs once through the repeated hour, the
            // rule Vixie cron uses and what "01:30 daily" means to whoever wrote it.
            //
            // The comparison is against the *previous fire*, not against `after` — `after` is the
            // scheduler tick, whose wall clock is almost never the boundary's, so a guard keyed on
            // it would fire only in the single tick that happened to land on `:30`. An earlier
            // version made exactly that mistake inside `CronSchedule.nextDate`, where the previous
            // fire is not in scope at all.
            //
            // `lastFiredAt` carries up to ±6s of jitter (see `jittered`), which can put it in the
            // adjacent minute; rounding to the nearest minute recovers the boundary it came from.
            if cron.pinsHour, let lastFiredAt = task.lastFiredAt {
                let lastSeconds = TimeInterval(lastFiredAt) / 1000
                let lastBoundary = Date(timeIntervalSince1970: (lastSeconds / 60).rounded() * 60)
                if CronSchedule.isSameLocalMinute(next, lastBoundary, in: zone) {
                    guard let following = cron.nextDate(after: next, in: zone) else { return nil }
                    return jittered(date: following, intervalMs: 60_000)
                }
            }
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
