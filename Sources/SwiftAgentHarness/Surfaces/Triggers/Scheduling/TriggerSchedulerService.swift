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
    /// When the previous `tick()` pass observed the clock, for the lateness bound above.
    private var lastTickAt: Date?

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

    func tick() async {
        do {
            ownsLock = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: config.lockIdentity)
            guard ownsLock else { return }
            let tasks = try listTasks()
            let now = Date()
            // The *observed* gap since the previous pass, not the configured sleep.
            //
            // `tick()` captures `now` once and then awaits each task's delivery inline — in
            // production a full streamed agent turn, seconds to minutes. So two tasks on the same
            // cron boundary are evaluated against clocks that can be a minute apart: the second one
            // does not fire on the first pass (its roll exceeds the elapsed time), and by the next
            // pass `now - boundary` has swallowed the first task's whole turn. Judging that against
            // `tickIntervalSeconds` reported the second task as `[missed]` — the same systematic
            // mislabelling this flag was just fixed to avoid, arriving by a different route.
            let granularity = max(
                config.tickIntervalSeconds,
                lastTickAt.map { now.timeIntervalSince($0) } ?? config.tickIntervalSeconds
            )
            lastTickAt = now
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
                if let scheduled = nextFire(for: task, now: now), scheduled.fireAt <= now {
                    let windowMs = task.lastFiredAt ?? task.createdAt
                    let fireResult: TriggerActivationResult
                    do {
                        // Judged against the *boundary* and this fire's own spread, not against a
                        // flat one-second window on the spread-adjusted time. The offset is re-rolled
                        // every tick, so the firing tick is simply the first whose roll fits the
                        // elapsed time — which made a flat threshold report ~half of all on-time
                        // cron fires as `[missed]` to the agent.
                        let missed = scheduled.isMissed(now: now, tickIntervalSeconds: granularity)
                        fireResult = try await fire(task: &task, missed: missed, windowMs: windowMs)
                    } catch {
                        // Contain the failure to this task. Letting it escape would discard the
                        // whole delta, so tasks already delivered this tick would lose their
                        // `lastFiredAt` bump and fire again on the next pass.
                        logger.warning("scheduler_fire_failed job=\(task.id) error=\(String(describing: error))")
                        // Consume the boundary anyway.
                        //
                        // Now that the next fire is derived from `lastFiredAt` rather than from
                        // `now`, leaving it unset pins `next` to this boundary permanently: `now`
                        // only moves further past it, so `fireAt <= now` holds on every subsequent
                        // tick and a provider outage becomes one delivery attempt per second until
                        // the task ages out. Redelivery is the durable queue's job — `fire` appends
                        // the run before delivering, so `catchUp()` retries it — not the tick loop's.
                        if task.recurring {
                            result.firedAt[task.id] = Int64(now.timeIntervalSince1970 * 1000)
                        } else {
                            result.removedIDs.insert(task.id)
                        }
                        continue
                    }
                    // A non-admitted result (unauthorized routing, rate-limit, budget) did not
                    // run a turn. Consuming the row here is how a rejected one-shot disappeared
                    // with no visible work.
                    guard fireResult.decision == .admitted else { continue }
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

    /// A scheduled fire, with the schedule's own instant kept alongside the spread-adjusted one.
    ///
    /// The two were previously collapsed into a single `Date`, which is why lateness could not be
    /// judged: `tick()` only saw `fireAt`, and `fireAt` legitimately trails the boundary by up to
    /// `spread` seconds. Testing that against a flat one-second threshold labelled roughly half of
    /// all on-time cron fires `[missed]`.
    struct ScheduledFire: Sendable, Equatable {
        /// The schedule's own instant: the cron boundary, the interval grid point, or the `at` time.
        var boundary: Date
        /// When the scheduler intends to run it — `boundary` plus a non-negative spread.
        var fireAt: Date
        /// The largest delay this fire was allowed. Zero when the fire is due immediately.
        var spread: TimeInterval
        /// Boundaries the skip-forward walk stepped over — ones the harness was not up for.
        ///
        /// This is *evidence*, not an estimate. The walk already knows the answer; before, it went
        /// only to a debug log and `isMissed` guessed from wall-clock slack instead, which agreed
        /// with the truth only most of the time.
        var skippedBoundaries: Int = 0

        /// Whether the boundary is materially in the past rather than merely spread-delayed.
        ///
        /// A fire that ran on time can still be up to `spread + tickInterval` late: the offset is
        /// re-rolled each tick, so the firing tick is the first whose roll is within the elapsed
        /// time, and the tick itself has granularity. Anything beyond that is a real catch-up —
        /// downtime, a stalled tick, or a boundary skipped forward to.
        func isMissed(now: Date, tickIntervalSeconds: TimeInterval) -> Bool {
            // A skipped boundary is missed by definition, whatever the clock says. Without this, a
            // three-day outage whose first tick happens to land within the spread window of a
            // boundary reported an ordinary, unflagged fire.
            if skippedBoundaries > 0 { return true }
            return now.timeIntervalSince(boundary) > spread + 2 * tickIntervalSeconds
        }
    }

    /// Spread-adjusted instant only. No production caller remains — `tick()` needs the boundary too
    /// — but the tests are written against this shape.
    func nextFireDate(for task: ScheduledTask, now: Date) -> Date? {
        nextFire(for: task, now: now)?.fireAt
    }

    func nextFire(for task: ScheduledTask, now: Date) -> ScheduledFire? {
        let anchorMs = task.lastFiredAt ?? task.createdAt
        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
        switch task.schedule.kind {
        case .at:
            guard let at = task.schedule.at, let date = ISO8601DateFormatter().date(from: at) else { return nil }
            if task.lastFiredAt != nil { return nil }
            return scheduledFire(boundary: date, intervalMs: nil)
        case .every:
            guard let ms = task.schedule.intervalMs else { return nil }
            // A task that has never run is due immediately, and is deliberately unspread: with a
            // non-negative offset, spreading `now` puts it strictly after `now` unless the roll is
            // exactly 0, so a spread first fire would never satisfy the tick's `fireAt <= now`.
            guard let lastFiredAt = task.lastFiredAt else {
                // Due immediately, and unspread — so it is not "late" either.
                return ScheduledFire(boundary: now, fireAt: now, spread: 0)
            }
            guard ms > 0 else { return nil }
            // Next point on a fixed grid anchored at `createdAt` — deliberately *not*
            // `lastFiredAt + interval`.
            //
            // `lastFiredAt` is the tick time, which already includes that fire's positive offset;
            // adding a fresh one compounds. At a one-minute interval with a 6s span that is ~1375
            // fires a day instead of 1440, and the loss accumulates linearly. A grid re-derived from
            // a fixed origin cannot drift, for the same reason `cron` cannot: the offset decides how
            // late a fire lands, never where the next one is.
            let interval = TimeInterval(ms) / 1000
            let created = TimeInterval(task.createdAt) / 1000
            let elapsed = TimeInterval(lastFiredAt) / 1000 - created
            let step = (elapsed / interval).rounded(.down) + 1
            let base = Date(timeIntervalSince1970: created + step * interval)
            // Backlog is skipped rather than replayed, as with `cron`: one grid point is returned,
            // and the fire moves `lastFiredAt` to `now`, so the next step is computed from there.
            return scheduledFire(boundary: base, intervalMs: ms)
        case .cron:
            guard let expr = task.schedule.expr, let cron = try? CronSchedule(expression: expr) else { return nil }
            let zone = task.resolvedTimeZone
            // Anchored on the previous fire, never on `now`.
            //
            // `CronSchedule.nextDate` is strictly greater than its input, so anchoring on `now` made
            // `next > now` on every tick and left the tick's `fireAt <= now` guard satisfiable only
            // when a *negative* jitter roll dragged the boundary back across `now`. That is why
            // roughly one boundary in six was silently skipped and the rest fired early, sometimes
            // twice. Anchoring on the last fire makes a due boundary land at or before `now` on its
            // own, so the offset no longer decides whether the task runs at all.
            guard var next = nextBoundary(cron: cron, after: anchor, zone: zone, lastFiredAt: task.lastFiredAt) else {
                return nil
            }
            // Standard cron semantics: missed boundaries are skipped, not replayed. Advance to the
            // most recent boundary that is already due, so a harness that was down for three days
            // fires once on return rather than once per missed boundary per tick.
            var skipped = 0
            // `>= 60`, not `<= now`: two cron boundaries are never less than a minute apart, so a
            // boundary less than a minute stale cannot have a successor that is also due. Without
            // this the loop runs on every tick of the ~6s window between a boundary and its fire,
            // and each iteration costs a full `nextDate` minute-walk — cheap for `0 * * * *`,
            // seconds of blocked actor for something like `0 3 1 1 *`.
            while now.timeIntervalSince(next) >= 60, skipped < Self.maxSkippedBoundaries {
                guard let following = nextBoundary(cron: cron, after: next, zone: zone, lastFiredAt: nil),
                      following <= now else { break }
                next = following
                skipped += 1
            }
            if skipped > 0 {
                logger.debug("scheduler_skipped_missed_boundaries job=\(task.id) count=\(skipped)")
            }
            return scheduledFire(boundary: next, intervalMs: 60_000, skippedBoundaries: skipped)
        }
    }

    /// Bound on the skip-forward walk. A minute-resolution cron left un-fired for 90 days is ~130k
    /// boundaries; the cap keeps one pathological task from stalling a tick.
    ///
    /// Hitting it is harmless: the capped `next` is still stale, so the task fires on that same tick
    /// and `lastFiredAt` jumps to `now`, which resets the anchor. There is no second capped walk.
    private static let maxSkippedBoundaries = 10_000

    /// Next boundary strictly after `after`, with the daylight-saving fall-back rule applied.
    ///
    /// Factored out because the skip-forward walk needs the same rule the first computation does.
    /// Pass `lastFiredAt: nil` for subsequent steps of that walk: the rule exists to avoid re-running
    /// a boundary that already fired, and a boundary reached mid-walk by definition has not.
    private func nextBoundary(
        cron: CronSchedule,
        after: Date,
        zone: TimeZone?,
        lastFiredAt: Int64?
    ) -> Date? {
        guard let next = cron.nextDate(after: after, in: zone) else { return nil }
        // Fall-back: a pinned-hour job runs once through the repeated hour (Vixie's rule, and what
        // "01:30 daily" means to whoever wrote it). `lastFiredAt` carries up to `span` seconds of
        // jitter, so it is rounded to the nearest minute to recover the boundary it came from.
        guard cron.pinsHour, let lastFiredAt else { return next }
        let lastSeconds = TimeInterval(lastFiredAt) / 1000
        let lastBoundary = Date(timeIntervalSince1970: (lastSeconds / 60).rounded() * 60)
        guard CronSchedule.isSameLocalMinute(next, lastBoundary, in: zone) else { return next }
        return cron.nextDate(after: next, in: zone)
    }

    /// Spread load around a boundary by delaying, never by arriving early.
    ///
    /// The offset used to be `Double.random(in: -span ... span)`. The negative half was not a
    /// scheduling nicety — it was the mechanism that made recurring cron fire at all, because the
    /// boundary was computed from `now` and was therefore always in the future. Fixing the anchor
    /// above is what makes a non-negative offset safe: a due boundary is now at or before `now` on
    /// its own, and the offset only decides *how late* within `span` the fire lands.
    ///
    /// Non-negative is also the correct semantics independently. A job scheduled for 09:00 may run
    /// at 09:00:04 and must never run at 08:59:56 — and once a fire happens at or after its
    /// boundary, the next computation returns the following boundary, so the same one cannot fire
    /// twice.
    /// Named to stay distinct from `fire(task:missed:windowMs:)`, which performs delivery.
    private func scheduledFire(
        boundary: Date,
        intervalMs: Int64?,
        skippedBoundaries: Int = 0
    ) -> ScheduledFire {
        let span = Self.spread(intervalMs: intervalMs)
        let offset = Double.random(in: 0 ... span)
        return ScheduledFire(
            boundary: boundary,
            fireAt: boundary.addingTimeInterval(offset),
            spread: span,
            skippedBoundaries: skippedBoundaries
        )
    }

    /// How far past its boundary a fire may be spread, to keep every task in a deployment from
    /// landing on the same second.
    private static func spread(intervalMs: Int64?) -> TimeInterval {
        let maxSpread: TimeInterval = 60
        guard let intervalMs else { return min(5, maxSpread) }
        // Clamped at zero: a negative interval would make `Double.random(in: 0 ... span)` trap on an
        // invalid range. Unreachable today (`guard ms > 0` upstream, plus the scanner's 1s floor),
        // but that guard is far from here and this helper is the one that would crash.
        return max(0, min(TimeInterval(intervalMs) / 1000 * 0.10, maxSpread))
    }
}
