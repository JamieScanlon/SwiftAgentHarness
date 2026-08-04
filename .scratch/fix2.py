p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()

# ---- 1. a failed delivery must not retry at 1 Hz forever --------------------
old = '''                    } catch {
                        // Contain the failure to this task. Letting it escape would discard the
                        // whole delta, so tasks already delivered this tick would lose their
                        // `lastFiredAt` bump and fire again on the next pass.
                        logger.warning("scheduler_fire_failed job=\\(task.id) error=\\(String(describing: error))")
                        continue
                    }'''
new = '''                    } catch {
                        // Contain the failure to this task. Letting it escape would discard the
                        // whole delta, so tasks already delivered this tick would lose their
                        // `lastFiredAt` bump and fire again on the next pass.
                        logger.warning("scheduler_fire_failed job=\\(task.id) error=\\(String(describing: error))")
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
                    }'''
assert s.count(old) == 1, 'catch anchor %d' % s.count(old)
s = s.replace(old, new)

# ---- 2. `every` must not drift ---------------------------------------------
old = '''            guard let lastFiredAt = task.lastFiredAt else { return now }
            let base = Date(timeIntervalSince1970: TimeInterval(lastFiredAt) / 1000)
                .addingTimeInterval(TimeInterval(ms) / 1000)
            // No backlog replay: `lastFiredAt` is the tick time, so after one late fire the next base
            // is one interval past *that*, not past the boundary it missed.
            return jittered(date: base, intervalMs: ms)'''
new = '''            guard let lastFiredAt = task.lastFiredAt else { return now }
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
            return jittered(date: base, intervalMs: ms)'''
assert s.count(old) == 1, 'every anchor %d' % s.count(old)
s = s.replace(old, new)

# ---- 4. don't pay a full cron walk inside the post-boundary jitter window ---
old = '''            var skipped = 0
            while next <= now, skipped < Self.maxSkippedBoundaries {'''
new = '''            var skipped = 0
            // `>= 60`, not `<= now`: two cron boundaries are never less than a minute apart, so a
            // boundary less than a minute stale cannot have a successor that is also due. Without
            // this the loop runs on every tick of the ~6s window between a boundary and its fire,
            // and each iteration costs a full `nextDate` minute-walk — cheap for `0 * * * *`,
            // seconds of blocked actor for something like `0 3 1 1 *`.
            while now.timeIntervalSince(next) >= 60, skipped < Self.maxSkippedBoundaries {'''
assert s.count(old) == 1, 'skip loop anchor %d' % s.count(old)
s = s.replace(old, new)

# ---- style: the cap comment described something that never happens ----------
old = '''    /// Bound on the skip-forward walk. A minute-resolution cron left un-fired for 90 days is ~130k
    /// boundaries; the cap keeps one pathological task from stalling a tick, and the walk resumes on
    /// the next one.'''
new = '''    /// Bound on the skip-forward walk. A minute-resolution cron left un-fired for 90 days is ~130k
    /// boundaries; the cap keeps one pathological task from stalling a tick.
    ///
    /// Hitting it is harmless: the capped `next` is still stale, so the task fires on that same tick
    /// and `lastFiredAt` jumps to `now`, which resets the anchor. There is no second capped walk.'''
assert s.count(old) == 1, 'cap doc anchor %d' % s.count(old)
s = s.replace(old, new)

open(p, 'w').write(s)
print('ok')
