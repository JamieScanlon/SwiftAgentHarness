p = 'Tests/SwiftAgentHarnessTests/Surfaces/Triggers/Scheduling/SchedulerFirePredicateTests.swift'
s = open(p).read()

marker = '''    /// `every` had the same shape:'''
assert s.count(marker) == 1, 'insert anchor %d' % s.count(marker)

block = '''    // MARK: - Lateness

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
        #expect(scheduled.isMissed(now: now, tickIntervalSeconds: 1))
    }

    /// An interval task that has never run is due immediately and unspread, so it must not be
    /// announced as late on its very first fire.
    @Test("a first interval fire is not reported as missed")
    func firstIntervalFireIsNotMissed() async throws {
        let scheduler = makeScheduler()
        let now = try date("2026-06-01T09:00:00Z")
        let task = ScheduledTask(
            id: "every-\\(UUID().uuidString)",
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

'''
s = s.replace(marker, block + marker, 1)
open(p, 'w').write(s)
print('ok')
