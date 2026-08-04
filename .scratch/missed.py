p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()

# ---------------------------------------------------------------- 1. the pair
old = '''    func nextFireDate(for task: ScheduledTask, now: Date) -> Date? {'''
new = '''    /// A scheduled fire, with the schedule's own instant kept alongside the spread-adjusted one.
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

        /// Whether the boundary is materially in the past rather than merely spread-delayed.
        ///
        /// A fire that ran on time can still be up to `spread + tickInterval` late: the offset is
        /// re-rolled each tick, so the firing tick is the first whose roll is within the elapsed
        /// time, and the tick itself has granularity. Anything beyond that is a real catch-up —
        /// downtime, a stalled tick, or a boundary skipped forward to.
        func isMissed(now: Date, tickIntervalSeconds: TimeInterval) -> Bool {
            now.timeIntervalSince(boundary) > spread + 2 * tickIntervalSeconds
        }
    }

    /// Spread-adjusted instant only. Retained because it is the shape the tests and callers use.
    func nextFireDate(for task: ScheduledTask, now: Date) -> Date? {
        nextFire(for: task, now: now)?.fireAt
    }

    func nextFire(for task: ScheduledTask, now: Date) -> ScheduledFire? {'''
assert s.count(old) == 1, 'signature anchor %d' % s.count(old)
s = s.replace(old, new)

# ---------------------------------------------------------------- 2. returns
old = '''            if task.lastFiredAt != nil { return nil }
            return jittered(date: date, intervalMs: nil)'''
new = '''            if task.lastFiredAt != nil { return nil }
            return scheduledFire(boundary: date, intervalMs: nil)'''
assert s.count(old) == 1, 'at return %d' % s.count(old)
s = s.replace(old, new)

old = '''            guard let lastFiredAt = task.lastFiredAt else { return now }'''
new = '''            guard let lastFiredAt = task.lastFiredAt else {
                // Due immediately, and unspread — so it is not "late" either.
                return ScheduledFire(boundary: now, fireAt: now, spread: 0)
            }'''
assert s.count(old) == 1, 'every first %d' % s.count(old)
s = s.replace(old, new)

old = '''            return jittered(date: base, intervalMs: ms)'''
new = '''            return scheduledFire(boundary: base, intervalMs: ms)'''
assert s.count(old) == 1, 'every return %d' % s.count(old)
s = s.replace(old, new)

old = '''            return jittered(date: next, intervalMs: 60_000)'''
new = '''            return scheduledFire(boundary: next, intervalMs: 60_000)'''
assert s.count(old) == 1, 'cron return %d' % s.count(old)
s = s.replace(old, new)

# ---------------------------------------------------------------- 3. spread
old = '''    private func jittered(date: Date, intervalMs: Int64?) -> Date {
        let maxJitter: TimeInterval = 60
        let pct = 0.10
        let span: TimeInterval
        if let intervalMs {
            span = min(TimeInterval(intervalMs) / 1000 * pct, maxJitter)
        } else {
            span = min(5, maxJitter)
        }
        let offset = Double.random(in: 0 ... span)
        return date.addingTimeInterval(offset)
    }'''
new = '''    /// Named to stay distinct from `fire(task:missed:windowMs:)`, which performs delivery.
    private func scheduledFire(boundary: Date, intervalMs: Int64?) -> ScheduledFire {
        let span = Self.spread(intervalMs: intervalMs)
        let offset = Double.random(in: 0 ... span)
        return ScheduledFire(boundary: boundary, fireAt: boundary.addingTimeInterval(offset), spread: span)
    }

    /// How far past its boundary a fire may be spread, to keep every task in a deployment from
    /// landing on the same second.
    private static func spread(intervalMs: Int64?) -> TimeInterval {
        let maxSpread: TimeInterval = 60
        guard let intervalMs else { return min(5, maxSpread) }
        return min(TimeInterval(intervalMs) / 1000 * 0.10, maxSpread)
    }'''
assert s.count(old) == 1, 'jittered anchor %d' % s.count(old)
s = s.replace(old, new)

# ---------------------------------------------------------------- 4. tick
old = '''                if let fireAt = nextFireDate(for: task, now: now), fireAt <= now {'''
new = '''                if let scheduled = nextFire(for: task, now: now), scheduled.fireAt <= now {'''
assert s.count(old) == 1, 'tick guard %d' % s.count(old)
s = s.replace(old, new)

old = '''                        _ = try await fire(task: &task, missed: fireAt < now.addingTimeInterval(-1), windowMs: windowMs)'''
new = '''                        // Judged against the *boundary* and this fire's own spread, not against a
                        // flat one-second window on the spread-adjusted time. The offset is re-rolled
                        // every tick, so the firing tick is simply the first whose roll fits the
                        // elapsed time — which made a flat threshold report ~half of all on-time
                        // cron fires as `[missed]` to the agent.
                        let missed = scheduled.isMissed(
                            now: now,
                            tickIntervalSeconds: config.tickIntervalSeconds
                        )
                        _ = try await fire(task: &task, missed: missed, windowMs: windowMs)'''
assert s.count(old) == 1, 'missed anchor %d' % s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
