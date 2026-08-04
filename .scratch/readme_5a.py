p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/README.md'
s = open(p).read()

section = '''## File events: one directory, two roles

`events/` is both an event **queue** and a **configuration store**, and the template
(`file-event-triggers.md` § Two patterns, kept distinct) is explicit that mixing them "is a category
error that produces confusing double-fires and phantom handlers." This surface mixes them anyway, on
purpose — the divergence and its reasoning are recorded here rather than left to be rediscovered.

| `type` | Role | Lifecycle |
|---|---|---|
| `immediate` | Queue event — the file *is* the trigger | Consumed, moved to `.processing/`, deleted |
| `periodic` | Configuration — registers a recurring `ScheduledTask` | Persists; deleting the file unregisters the task |
| `one-shot` | Configuration — registers a future-dated task | Persists until fired; deleting unregisters |

**Why one directory.** The alternative was `events/` for immediates and `subscriptions/` for the
rest, which is more spec-faithful but breaks every existing drop path and buys little: the sync code
already dispatches on `type` cleanly, and the two roles never share a file. What actually removes the
"phantom handler" hazard is not separate directories but the fact that subscriptions register through
`TriggerRegistrationService` like everything else — so a file-registered task is creator-stamped,
trust-clamped, audited, and **visible to `schedule_list`**. Before that it was an orphaned store row
nobody could see or delete.

**The writer.** `FileEventQueueWriter.writeSubscription` is the configuration-half counterpart to
`writeImmediate`. Only the queue half had a writer, so the harness could produce its own immediates
but not its own subscriptions — those had to come from outside, and nothing could round-trip what it
wrote. `removeSubscription` is the other end: deleting the file is what unregisters the task.

Writing is all it does. Registration still happens when the watcher notices the file and
`FileEventPeriodicSync` / `FileEventScheduledSync` route it through the endpoint — deliberately, so a
file the harness wrote and a file dropped by hand take exactly the same path to becoming a task.

**Basenames are narrow** (`^[a-z0-9][a-z0-9_-]{0,63}$`), the same charset as webhook route names and
for the same reason: the string becomes a path component *and* the tail of the scheduled-task id
(`file-periodic:<basename>`). `..` would escape the directory; a leading `.` would be written and
then never seen, because the queue skips dotfiles.

**Task ids have one spelling.** `FileEventQueueLayout.taskID(forSubscription:kind:)`. The two
prefixes were previously written out at four call sites across the two sync types and their removal
paths; a writer that guessed differently would register under one id and unregister under another.

**Trust ordering is load-bearing.** The sidecar is written before the payload in both writers,
because the watcher fires on the `.json` — a sidecar written second can be missed and the event
resolved at the default `unknown-party`. The filesystem grants no trust by itself: the drop path is
local, so the *creator* is the machine owner (`RegistrationAuthority.localFileDrop`), while the
*content* trust comes from the `.trust` sidecar.

### Not in this phase

Runtime watch-path registration (a `watch_subscribe` op). The events directory is fixed at
`FileEventQueueService.init` and `FileEventDirectoryWatchSource` opens exactly one path,
non-recursively. No reference harness supports runtime watch registration — the one whose entire API
is file-drop still has a single fixed directory — and the interesting version of the feature ("watch
this project directory for changes") is a different problem from trigger registration.

'''

anchor = '## Upcoming work (next steps)'
assert s.count(anchor) == 1, 'anchor %d' % s.count(anchor)
s = s.replace(anchor, section + anchor, 1)
open(p, 'w').write(s)
print('ok')
