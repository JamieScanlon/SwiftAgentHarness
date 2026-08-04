p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()

# ---------------------------------------------------------------- cron + every
old_start = s.index('        case .every:\n            guard let ms = task.schedule.intervalMs else { return nil }')
old_end = s.index('    }\n\n', s.index('        case .cron:', old_start))
old = s[old_start:old_end]

new = '''        case .every:
            guard let ms = task.schedule.intervalMs else { return nil }
            // A task that has never run is due immediately, and is deliberately not jittered: with a
            // non-negative offset, `jittered(now)` is `> now` unless the roll is exactly 0, so a
            // jittered first fire would never satisfy the tick's `fireAt <= now`.
            guard let lastFiredAt = task.lastFiredAt else { return now }
            let base = Date(timeIntervalSince1970: TimeInterval(lastFiredAt) / 1000)
                .addingTimeInterval(TimeInterval(ms) / 1000)
            // No backlog replay: `lastFiredAt` is the tick time, so after one late fire the next base
            // is one interval past *that*, not past the boundary it missed.
            return jittered(date: base, intervalMs: ms)
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
            while next <= now, skipped < Self.maxSkippedBoundaries {
                guard let following = nextBoundary(cron: cron, after: next, zone: zone, lastFiredAt: nil),
                      following <= now else { break }
                next = following
                skipped += 1
            }
            if skipped > 0 {
                logger.debug("scheduler_skipped_missed_boundaries job=\\(task.id) count=\\(skipped)")
            }
            return jittered(date: next, intervalMs: 60_000)
'''
s = s[:old_start] + new + s[old_end:]

# ---------------------------------------------------------------- helper + cap
old = '''    private func jittered(date: Date, intervalMs: Int64?) -> Date {'''
new = '''    /// Bound on the skip-forward walk. A minute-resolution cron left un-fired for 90 days is ~130k
    /// boundaries; the cap keeps one pathological task from stalling a tick, and the walk resumes on
    /// the next one.
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
    private func jittered(date: Date, intervalMs: Int64?) -> Date {'''
assert s.count(old) == 1, 'jittered anchor %d' % s.count(old)
s = s.replace(old, new)

old = '''        let offset = Double.random(in: -span ... span)'''
assert s.count(old) == 1, 'offset %d' % s.count(old)
s = s.replace(old, '''        let offset = Double.random(in: 0 ... span)''')

open(p, 'w').write(s)
print('ok')
