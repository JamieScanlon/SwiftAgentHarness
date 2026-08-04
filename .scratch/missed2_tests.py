p = 'Tests/SwiftAgentHarnessTests/Surfaces/Triggers/Scheduling/SchedulerFirePredicateTests.swift'
s = open(p).read()

# style: never mutated
old = '''        var task = ScheduledTask(
            id: "every-\\(UUID().uuidString)",
            createdAt: Int64(start.timeIntervalSince1970 * 1000),
            lastFiredAt: Int64(start.timeIntervalSince1970 * 1000),'''
new = '''        let task = ScheduledTask(
            id: "every-\\(UUID().uuidString)",
            createdAt: Int64(start.timeIntervalSince1970 * 1000),
            lastFiredAt: Int64(start.timeIntervalSince1970 * 1000),'''
assert s.count(old) == 1, 'var task %d' % s.count(old)
s = s.replace(old, new)

# #4: the existing skip test has a 225x margin and passes under the old rule too.
old = '''        let scheduled = try #require(await scheduler.nextFire(for: task, now: now))
        #expect(scheduled.isMissed(now: now, tickIntervalSeconds: 1))
    }'''
new = '''        let scheduled = try #require(await scheduler.nextFire(for: task, now: now))
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
    }'''
assert s.count(old) == 1, 'skip test %d' % s.count(old)
s = s.replace(old, new)

# #3: nothing asserted the flag through the real path.
marker = '''    // MARK: - Lateness'''
assert s.count(marker) == 1, 'lateness marker %d' % s.count(marker)
block = '''    /// The headline claim, asserted through the path production uses rather than against a
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
            #expect(flagged.isEmpty, "punctual fires reported as missed at \\(flagged)")
        }
    }

    // MARK: - Lateness'''
s = s.replace(marker, block, 1)
open(p, 'w').write(s)
print('ok')
