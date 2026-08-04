p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()

old = '''    private func jittered(date: Date, intervalMs: Int64?) -> Date {
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
    }'''

new = '''    /// Spread load around a boundary by delaying, never by arriving early.
    ///
    /// The offset used to be `Double.random(in: -span ... span)`, and the negative half was a
    /// double-fire bug rather than a scheduling nicety:
    ///
    /// 1. `nextFireDate` re-rolls the offset on every call, so it is not a pure function — two ticks
    ///    a second apart get different answers for the same boundary.
    /// 2. `tick()` fires whenever `fireAt <= now`. In the `span` seconds *before* a boundary,
    ///    `nextDate(after: now)` still returns that boundary, so any roll landing at or below `now`
    ///    fired it early.
    /// 3. Firing sets `lastFiredAt`, but for `cron` the next computation uses `now`, not
    ///    `lastFiredAt` — so the following tick, still before the boundary, could roll again and
    ///    fire the same boundary a second time.
    /// 4. Nothing caught the duplicate: the idempotency key is `"\\(task.id):\\(lastFiredAt)"`, and
    ///    `lastFiredAt` had just changed, so the second run got a fresh key.
    ///
    /// A non-negative offset closes all four. It is also the correct semantics independently: a job
    /// scheduled for 09:00 may run at 09:00:04, and must never run at 08:59:56. Once a fire happens
    /// at or after its boundary, `nextDate(after: now)` necessarily returns the *following* boundary,
    /// so the same one cannot be fired twice.
    private func jittered(date: Date, intervalMs: Int64?) -> Date {
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

assert s.count(old) == 1, 'jitter anchor %d' % s.count(old)
s = s.replace(old, new)

# `missed` now means what it says: with a non-negative offset `fireAt >= boundary`, so a fire more
# than a second late is a genuine catch-up rather than an artefact of negative jitter.
old = '''                        _ = try await fire(task: &task, missed: fireAt < now.addingTimeInterval(-1), windowMs: windowMs)'''
new = '''                        // `fireAt >= boundary` now holds (see `jittered`), so this reads as "the
                        // boundary is more than a second in the past" — a real catch-up, not an
                        // early fire that negative jitter had dragged backwards.
                        _ = try await fire(task: &task, missed: fireAt < now.addingTimeInterval(-1), windowMs: windowMs)'''
assert s.count(old) == 1, 'missed anchor %d' % s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
