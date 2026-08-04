import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

/// These drive the *eligibility predicate* `nextFireDate(for:now:)! <= now` — the thing `tick()`
/// actually asks — rather than only inspecting the returned date.
///
/// That distinction is the whole point of this file. A previous attempt at this fix asserted only
/// that the returned date advanced past the boundary it had fired, which was true *because the
/// scheduler could no longer fire at all*: the test was evidence of the bug it was meant to prevent.
@Suite("Scheduler fire predicate")
struct SchedulerFirePredicateTests {
    private func makeScheduler() -> TriggerSchedulerService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fire-pred-\(UUID().uuidString)")
        return TriggerSchedulerService(
            store: ScheduledTaskStore(fileURL: directory.appendingPathComponent("tasks.json")),
            deliver: { _ in TriggerActivationResult(decision: .admitted, sessionID: nil) },
            lockURL: directory.appendingPathComponent("scheduler.lock"),
            logger: Logger(label: "test")
        )
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    private func cronTask(_ expr: String, lastFired: Date?, created: Date) -> ScheduledTask {
        ScheduledTask(
            id: "pred-\(UUID().uuidString)",
            createdAt: Int64(created.timeIntervalSince1970 * 1000),
            lastFiredAt: lastFired.map { Int64($0.timeIntervalSince1970 * 1000) },
            schedule: ScheduledTaskSchedule(kind: .cron, expr: expr),
            payloadKind: .agentTurn,
            payloadText: "x",
            recurring: true,
            timezone: "UTC"
        )
    }

    /// Simulate `tick()`'s decision over a span of one-second ticks, returning the instants at which
    /// it would have fired. `lastFiredAt` advances to the tick time exactly as `tick()` sets it.
    private func simulate(
        _ scheduler: TriggerSchedulerService,
        task initial: ScheduledTask,
        from start: Date,
        seconds: Int
    ) async throws -> [Date] {
        var task = initial
        var fires: [Date] = []
        for step in 0 ..< seconds {
            let now = start.addingTimeInterval(TimeInterval(step))
            guard let fireAt = await scheduler.nextFireDate(for: task, now: now), fireAt <= now else { continue }
            fires.append(now)
            task.lastFiredAt = Int64(now.timeIntervalSince1970 * 1000)
        }
        return fires
    }

    /// The defect this file exists for: anchoring on `now` made `next > now` on every tick, so the
    /// predicate was satisfiable only by a negative jitter roll. Roughly one boundary in six was
    /// silently skipped.
    @Test("a recurring cron fires exactly once per boundary")
    func firesOncePerBoundary() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T08:00:00Z")
        let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)

        // 7210s, not 7201: the offset is re-rolled every tick, so the final boundary needs at least
        // `span` seconds of ticks after it to be certain of firing. Ending at 11:00:03 gave it only
        // deltas 0-3 and made this ~28% flaky.
        let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:00:03Z"), seconds: 7210)
        #expect(fires.count == 2, "expected 10:00 and 11:00, got \(fires)")
    }

    /// Sampled, because the offset is random and a single run passed ~84% of the time even with the
    /// bug present.
    @Test("no boundary is silently skipped across repeated runs")
    func noBoundaryIsSkipped() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T08:00:00Z")
        for _ in 0 ..< 40 {
            let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
            let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:00:03Z"), seconds: 3700)
            #expect(fires.count == 1, "expected exactly the 10:00 boundary, got \(fires)")
        }
    }

    /// A job scheduled for 10:00 must never run at 09:59:5x.
    @Test("a fire never lands before its boundary")
    func neverFiresEarly() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T08:00:00Z")
        let boundary = try date("2026-06-01T10:00:00Z")
        for _ in 0 ..< 40 {
            let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
            let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:59:30Z"), seconds: 60)
            // Without this the test passes when nothing fires at all — which is exactly the failure
            // mode of the previous attempt at this fix, so an empty-tolerant assertion here would be
            // blind to the regression it exists to catch.
            #expect(fires.count == 1, "expected the 10:00 boundary to fire once, got \(fires)")
            for fire in fires {
                #expect(fire >= boundary, "fired early at \(fire)")
            }
        }
    }

    /// Standard cron: an outage does not replay the backlog. Three days down, one fire on return.
    @Test("missed boundaries are skipped, not replayed")
    func missedBoundariesAreSkipped() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T00:00:00Z")
        // Last fired at 09:00 on the 1st; the harness comes back at 12:30 on the 4th — 75 missed
        // hourly boundaries.
        let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
        let fires = try await simulate(scheduler, task: task, from: try date("2026-06-04T12:30:00Z"), seconds: 120)
        #expect(fires.count == 1, "one catch-up fire, not 75, got \(fires.count)")
    }

    /// After the catch-up the task must resume normally rather than staying stuck in the past.
    @Test("the schedule resumes at the next boundary after a catch-up")
    func resumesAfterCatchUp() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T00:00:00Z")
        var task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
        let caughtUp = try await simulate(scheduler, task: task, from: try date("2026-06-04T12:30:00Z"), seconds: 120)
        let catchUpAt = try #require(caughtUp.first)
        task.lastFiredAt = Int64(catchUpAt.timeIntervalSince1970 * 1000)

        // From just after the catch-up through 13:00:30 — exactly one further boundary.
        // 1830s, not 1800: the window has to extend past the boundary by more than the 6s jitter
        // span, or the single tick that lands exactly on it needs a near-zero roll to fire.
        let after = try await simulate(scheduler, task: task, from: catchUpAt.addingTimeInterval(1), seconds: 1830)
        #expect(after.count == 1, "expected the 13:00 boundary, got \(after)")
        // Both sides hoisted: `try` may not appear to the right of a non-assignment operator, and
        // the macro argument is type-checked before expansion.
        let resumed = try #require(after.first)
        let nextBoundary = try date("2026-06-04T13:00:00Z")
        #expect(resumed >= nextBoundary)
    }

    /// The headline claim, asserted through the path production uses rather than against a
    /// hand-built value: a punctual recurring cron fire is not announced to the agent as `[missed]`.
    ///
    /// The three threshold tests below construct `ScheduledFire` directly, which cannot catch a
    /// defect in how `tick()` *derives* its arguments — and that is exactly where the previous
    /// version went wrong.
    @Test("a punctual cron fire is never flagged missed, across repeated runs")
    func punctualFiresAreNotFlagged() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T08:00:00Z")
        for _ in 0 ..< 40 {
            var task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
            var flagged: [Date] = []
            for step in 0 ..< 3700 {
                let now = try date("2026-06-01T09:00:03Z").addingTimeInterval(TimeInterval(step))
                guard let scheduled = await scheduler.nextFire(for: task, now: now),
                      scheduled.fireAt <= now else { continue }
                if scheduled.isMissed(now: now, tickIntervalSeconds: 1) { flagged.append(now) }
                task.lastFiredAt = Int64(now.timeIntervalSince1970 * 1000)
            }
            #expect(flagged.isEmpty, "punctual fires reported as missed at \(flagged)")
        }
    }

    // MARK: - Lateness

    /// `missed` used to be `fireAt < now - 1s`, which is a test on the *spread-adjusted* time. Since
    /// the offset is re-rolled each tick, the firing tick is simply the first whose roll fits the
    /// elapsed time, so a perfectly punctual cron fire routinely trailed its own `fireAt` by more
    /// than a second — and ~half of all normal fires arrived at the agent prefixed `[missed]`.
    @Test("a fire spread within its own window is not reported as missed")
    func spreadIsNotMissed() throws {
        let boundary = try date("2026-06-01T10:00:00Z")
        let scheduled = TriggerSchedulerService.ScheduledFire(
            boundary: boundary,
            fireAt: boundary,
            spread: 6
        )
        // Fired 5s after the boundary, inside a 6s spread: punctual.
        #expect(scheduled.isMissed(now: boundary.addingTimeInterval(5), tickIntervalSeconds: 1) == false)
        // At the far edge of spread plus two ticks: still punctual.
        #expect(scheduled.isMissed(now: boundary.addingTimeInterval(8), tickIntervalSeconds: 1) == false)
    }

    /// The flag has to keep working for the case it exists for, or the fix would just be suppression.
    @Test("a boundary materially in the past is reported as missed")
    func realCatchUpIsMissed() throws {
        let boundary = try date("2026-06-01T10:00:00Z")
        let scheduled = TriggerSchedulerService.ScheduledFire(
            boundary: boundary,
            fireAt: boundary,
            spread: 6
        )
        #expect(scheduled.isMissed(now: boundary.addingTimeInterval(60), tickIntervalSeconds: 1))
        #expect(scheduled.isMissed(now: boundary.addingTimeInterval(3 * 3600), tickIntervalSeconds: 1))
    }

    /// The threshold scales with the schedule rather than being a flat constant: an hourly `every`
    /// is allowed a 60s spread, so 30s late is punctual for it and badly late for a cron boundary.
    @Test("the lateness threshold scales with the fire's own spread")
    func thresholdScalesWithSpread() throws {
        let boundary = try date("2026-06-01T10:00:00Z")
        let wide = TriggerSchedulerService.ScheduledFire(boundary: boundary, fireAt: boundary, spread: 60)
        let narrow = TriggerSchedulerService.ScheduledFire(boundary: boundary, fireAt: boundary, spread: 6)
        let now = boundary.addingTimeInterval(30)
        #expect(wide.isMissed(now: now, tickIntervalSeconds: 1) == false)
        #expect(narrow.isMissed(now: now, tickIntervalSeconds: 1))
    }

    /// A boundary reached by the skip-forward walk is by definition one the harness was not up for.
    @Test("a boundary skipped forward to is reported as missed")
    func skippedBoundaryIsMissed() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T00:00:00Z")
        let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
        let now = try date("2026-06-04T12:30:00Z")
        let scheduled = try #require(await scheduler.nextFire(for: task, now: now))
        #expect(scheduled.skippedBoundaries > 0)
        #expect(scheduled.isMissed(now: now, tickIntervalSeconds: 1))
    }

    /// The case wall-clock slack alone gets wrong, and the reason the skip count is carried rather
    /// than re-derived: a three-day outage whose first tick lands *inside* the spread window of a
    /// boundary. `now - boundary` is then ~4s against a threshold of 8, so a slack-only rule reports
    /// 74 dropped boundaries as an ordinary, unflagged fire.
    @Test("a catch-up landing inside the spread window is still reported as missed")
    func catchUpInsideSpreadWindowIsMissed() async throws {
        let scheduler = makeScheduler()
        let created = try date("2026-06-01T00:00:00Z")
        let task = cronTask("0 * * * *", lastFired: try date("2026-06-01T09:00:02Z"), created: created)
        // Four seconds past the 12:00 boundary — well inside `spread + 2 * tick`.
        let now = try date("2026-06-04T12:00:04Z")
        let scheduled = try #require(await scheduler.nextFire(for: task, now: now))
        #expect(now.timeIntervalSince(scheduled.boundary) < 8, "precondition: slack alone would say punctual")
        #expect(scheduled.skippedBoundaries > 0)
        #expect(scheduled.isMissed(now: now, tickIntervalSeconds: 1))
    }

    /// An interval task that has never run is due immediately and unspread, so it must not be
    /// announced as late on its very first fire.
    @Test("a first interval fire is not reported as missed")
    func firstIntervalFireIsNotMissed() async throws {
        let scheduler = makeScheduler()
        let now = try date("2026-06-01T09:00:00Z")
        let task = ScheduledTask(
            id: "every-\(UUID().uuidString)",
            createdAt: Int64(now.timeIntervalSince1970 * 1000),
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 600_000),
            payloadKind: .agentTurn,
            payloadText: "x",
            recurring: true
        )
        let scheduled = try #require(await scheduler.nextFire(for: task, now: now))
        #expect(scheduled.spread == 0)
        #expect(scheduled.isMissed(now: now, tickIntervalSeconds: 1) == false)
    }

    /// `every` had the same shape: on the first fire the base is `now`, so a non-negative offset made
    /// the predicate satisfiable only on an exact-zero roll — i.e. effectively never.
    @Test("an interval task fires promptly on its first tick")
    func intervalFiresFirstTick() async throws {
        let scheduler = makeScheduler()
        let now = try date("2026-06-01T09:00:00Z")
        for _ in 0 ..< 40 {
            let task = ScheduledTask(
                id: "every-\(UUID().uuidString)",
                createdAt: Int64(now.timeIntervalSince1970 * 1000),
                schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 600_000),
                payloadKind: .agentTurn,
                payloadText: "x",
                recurring: true
            )
            let fireAt = try #require(await scheduler.nextFireDate(for: task, now: now))
            #expect(fireAt <= now, "a never-run interval task is due immediately")
        }
    }

    @Test("an interval task then fires once per interval")
    func intervalFiresOncePerInterval() async throws {
        let scheduler = makeScheduler()
        let start = try date("2026-06-01T09:00:00Z")
        let task = ScheduledTask(
            id: "every-\(UUID().uuidString)",
            createdAt: Int64(start.timeIntervalSince1970 * 1000),
            lastFiredAt: Int64(start.timeIntervalSince1970 * 1000),
            schedule: ScheduledTaskSchedule(kind: .every, intervalMs: 60_000),
            payloadKind: .agentTurn,
            payloadText: "x",
            recurring: true
        )
        // 330s rather than 300: each fire lands 0-6s after its nominal interval, so five one-minute
        // intervals need a little more than five minutes of ticks to all land.
        let fires = try await simulate(scheduler, task: task, from: start.addingTimeInterval(1), seconds: 330)
        #expect(fires.count == 5, "expected five interval fires, got \(fires.count)")

        // The assertion that gives this test teeth. A count alone cannot fail on the defect this
        // file is about: it passes under both the old symmetric offset and a drifting one.
        //
        // `every` used to compute its next base as `lastFiredAt + interval`, and `lastFiredAt` is
        // the tick time — which already carries that fire's positive offset. Each fire therefore
        // pushed the next one further out, costing ~65 fires a day at a one-minute interval. Against
        // a grid anchored at `createdAt` the error cannot accumulate, so the fifth fire is still
        // within one jitter span of its nominal time rather than five.
        let fifth = try #require(fires.last)
        let nominal = start.addingTimeInterval(300)
        #expect(
            fifth.timeIntervalSince(nominal) < 10,
            "interval drift: fifth fire at \(fifth), nominally \(nominal)"
        )
    }
}
