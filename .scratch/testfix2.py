p = 'Tests/SwiftAgentHarnessTests/Surfaces/Triggers/Scheduling/SchedulerFirePredicateTests.swift'
s = open(p).read()

# ---- 5. the window was ~28% flaky: the last boundary only got deltas 0-3 ----
old = '''        // 09:00:03 through 11:00:03 — two boundaries (10:00 and 11:00).
        let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:00:03Z"), seconds: 7201)'''
new = '''        // 7210s, not 7201: the offset is re-rolled every tick, so the final boundary needs at least
        // `span` seconds of ticks after it to be certain of firing. Ending at 11:00:03 gave it only
        // deltas 0-3 and made this ~28% flaky.
        let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:00:03Z"), seconds: 7210)'''
assert s.count(old) == 1, 'window anchor %d' % s.count(old)
s = s.replace(old, new)

# ---- 7. an empty `fires` made this assert nothing ---------------------------
old = '''            let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:59:30Z"), seconds: 60)
            for fire in fires {
                #expect(fire >= boundary, "fired early at \\(fire)")
            }'''
new = '''            let fires = try await simulate(scheduler, task: task, from: try date("2026-06-01T09:59:30Z"), seconds: 60)
            // Without this the test passes when nothing fires at all — which is exactly the failure
            // mode of the previous attempt at this fix, so an empty-tolerant assertion here would be
            // blind to the regression it exists to catch.
            #expect(fires.count == 1, "expected the 10:00 boundary to fire once, got \\(fires)")
            for fire in fires {
                #expect(fire >= boundary, "fired early at \\(fire)")
            }'''
assert s.count(old) == 1, 'early anchor %d' % s.count(old)
s = s.replace(old, new)

# ---- 6. the interval test could not fail on anything this file is about -----
old = '''        task.timezone = nil
        // 330s rather than 300: each fire lands 0-6s after its nominal interval, so five one-minute
        // intervals need a little more than five minutes of ticks to all land.
        let fires = try await simulate(scheduler, task: task, from: start.addingTimeInterval(1), seconds: 330)
        #expect(fires.count == 5, "expected five interval fires, got \\(fires.count)")'''
new = '''        // 330s rather than 300: each fire lands 0-6s after its nominal interval, so five one-minute
        // intervals need a little more than five minutes of ticks to all land.
        let fires = try await simulate(scheduler, task: task, from: start.addingTimeInterval(1), seconds: 330)
        #expect(fires.count == 5, "expected five interval fires, got \\(fires.count)")

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
            "interval drift: fifth fire at \\(fifth), nominally \\(nominal)"
        )'''
assert s.count(old) == 1, 'interval anchor %d' % s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
