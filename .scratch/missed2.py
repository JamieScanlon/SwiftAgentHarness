p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()

# ---- 2. carry the ground truth instead of re-deriving it from wall-clock ----
old = '''        /// The largest delay this fire was allowed. Zero when the fire is due immediately.
        var spread: TimeInterval
'''
new = '''        /// The largest delay this fire was allowed. Zero when the fire is due immediately.
        var spread: TimeInterval
        /// Boundaries the skip-forward walk stepped over — ones the harness was not up for.
        ///
        /// This is *evidence*, not an estimate. The walk already knows the answer; before, it went
        /// only to a debug log and `isMissed` guessed from wall-clock slack instead, which agreed
        /// with the truth only most of the time.
        var skippedBoundaries: Int = 0
'''
assert s.count(old) == 1, 'field %d' % s.count(old)
s = s.replace(old, new)

old = '''        func isMissed(now: Date, tickIntervalSeconds: TimeInterval) -> Bool {
            now.timeIntervalSince(boundary) > spread + 2 * tickIntervalSeconds
        }'''
new = '''        func isMissed(now: Date, tickIntervalSeconds: TimeInterval) -> Bool {
            // A skipped boundary is missed by definition, whatever the clock says. Without this, a
            // three-day outage whose first tick happens to land within the spread window of a
            // boundary reported an ordinary, unflagged fire.
            if skippedBoundaries > 0 { return true }
            return now.timeIntervalSince(boundary) > spread + 2 * tickIntervalSeconds
        }'''
assert s.count(old) == 1, 'isMissed %d' % s.count(old)
s = s.replace(old, new)

old = '''    /// Named to stay distinct from `fire(task:missed:windowMs:)`, which performs delivery.
    private func scheduledFire(boundary: Date, intervalMs: Int64?) -> ScheduledFire {
        let span = Self.spread(intervalMs: intervalMs)
        let offset = Double.random(in: 0 ... span)
        return ScheduledFire(boundary: boundary, fireAt: boundary.addingTimeInterval(offset), spread: span)
    }'''
new = '''    /// Named to stay distinct from `fire(task:missed:windowMs:)`, which performs delivery.
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
    }'''
assert s.count(old) == 1, 'scheduledFire %d' % s.count(old)
s = s.replace(old, new)

old = '''            return scheduledFire(boundary: next, intervalMs: 60_000)'''
new = '''            return scheduledFire(boundary: next, intervalMs: 60_000, skippedBoundaries: skipped)'''
assert s.count(old) == 1, 'cron return %d' % s.count(old)
s = s.replace(old, new)

# ---- 1. measure the tick gap; do not assume the configured sleep -----------
old = '''            ownsLock = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: config.lockIdentity)
            guard ownsLock else { return }
            let tasks = try listTasks()
            let now = Date()'''
new = '''            ownsLock = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: config.lockIdentity)
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
            lastTickAt = now'''
assert s.count(old) == 1, 'tick now %d' % s.count(old)
s = s.replace(old, new)

old = '''                        let missed = scheduled.isMissed(
                            now: now,
                            tickIntervalSeconds: config.tickIntervalSeconds
                        )'''
new = '''                        let missed = scheduled.isMissed(now: now, tickIntervalSeconds: granularity)'''
assert s.count(old) == 1, 'missed call %d' % s.count(old)
s = s.replace(old, new)

old = '''    private var ownsLock = false'''
if s.count(old) == 1:
    s = s.replace(old, old + '''
    /// When the previous `tick()` pass observed the clock, for the lateness bound above.
    private var lastTickAt: Date?''')
else:
    import re
    m = re.search(r'\n(\s*)private var ownsLock[^\n]*\n', s)
    assert m, 'no ownsLock declaration'
    s = s[:m.end()] + '%sprivate var lastTickAt: Date?\n' % m.group(1) + s[m.end():]

# ---- style ----
old = '''    /// Spread-adjusted instant only. Retained because it is the shape the tests and callers use.'''
new = '''    /// Spread-adjusted instant only. No production caller remains — `tick()` needs the boundary too
    /// — but the tests are written against this shape.'''
assert s.count(old) == 1, 'doc %d' % s.count(old)
s = s.replace(old, new)

old = '''    private static func spread(intervalMs: Int64?) -> TimeInterval {
        let maxSpread: TimeInterval = 60
        guard let intervalMs else { return min(5, maxSpread) }
        return min(TimeInterval(intervalMs) / 1000 * 0.10, maxSpread)
    }'''
new = '''    private static func spread(intervalMs: Int64?) -> TimeInterval {
        let maxSpread: TimeInterval = 60
        guard let intervalMs else { return min(5, maxSpread) }
        // Clamped at zero: a negative interval would make `Double.random(in: 0 ... span)` trap on an
        // invalid range. Unreachable today (`guard ms > 0` upstream, plus the scanner's 1s floor),
        // but that guard is far from here and this helper is the one that would crash.
        return max(0, min(TimeInterval(intervalMs) / 1000 * 0.10, maxSpread))
    }'''
assert s.count(old) == 1, 'spread %d' % s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
