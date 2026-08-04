p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/Scheduling/TriggerSchedulerService.swift'
s = open(p).read()
old = '''            // A task that has never run is due immediately, and is deliberately not jittered: with a
            // non-negative offset, `jittered(now)` is `> now` unless the roll is exactly 0, so a
            // jittered first fire would never satisfy the tick's `fireAt <= now`.'''
new = '''            // A task that has never run is due immediately, and is deliberately unspread: with a
            // non-negative offset, spreading `now` puts it strictly after `now` unless the roll is
            // exactly 0, so a spread first fire would never satisfy the tick's `fireAt <= now`.'''
assert s.count(old) == 1, 'stale comment %d' % s.count(old)
open(p, 'w').write(s.replace(old, new))
print('ok')
