import re

# Consolidate the task-id spelling so the writer cannot drift from the syncs.
p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/FileEvent/FileEventPeriodicSync.swift'
s = open(p).read()
old = '''        let taskID = FileEventQueueLayout.periodicTaskIDPrefix + eventURL.deletingPathExtension().lastPathComponent'''
new = '''        let taskID = FileEventQueueLayout.taskID(
            forSubscription: eventURL.deletingPathExtension().lastPathComponent,
            kind: .periodic
        )'''
assert s.count(old) == 1, 'periodic register %d' % s.count(old)
s = s.replace(old, new)

old = '''        let base = (filename as NSString).deletingPathExtension
        let taskID = FileEventQueueLayout.periodicTaskIDPrefix + base
        _ = try registration.deleteSchedule(id: taskID, authority: authority)'''
new = '''        let base = (filename as NSString).deletingPathExtension
        let taskID = FileEventQueueLayout.taskID(forSubscription: base, kind: .periodic)
        _ = try registration.deleteSchedule(id: taskID, authority: authority)'''
assert s.count(old) == 1, 'periodic remove %d' % s.count(old)
s = s.replace(old, new)
open(p, 'w').write(s)

p = 'Sources/SwiftAgentHarness/Surfaces/Triggers/FileEvent/FileEventScheduledSync.swift'
s = open(p).read()
old = '''        let taskID = FileEventScheduledFileKind.oneShotTaskIDPrefix + eventURL.deletingPathExtension().lastPathComponent'''
new = '''        let taskID = FileEventQueueLayout.taskID(
            forSubscription: eventURL.deletingPathExtension().lastPathComponent,
            kind: .oneShot
        )'''
assert s.count(old) == 1, 'one-shot register %d' % s.count(old)
s = s.replace(old, new)

old = '''        _ = try registration.deleteSchedule(
            id: FileEventQueueLayout.periodicTaskIDPrefix + base,
            authority: authority
        )'''
new = '''        // Both prefixes are probed: the file's own type is not knowable once it has been deleted,
        // so removal has to cover either kind it might have been.
        _ = try registration.deleteSchedule(
            id: FileEventQueueLayout.taskID(forSubscription: base, kind: .periodic),
            authority: authority
        )'''
assert s.count(old) == 1, 'one-shot remove periodic %d' % s.count(old)
s = s.replace(old, new)

m = re.search(
    r'_ = try registration\.deleteSchedule\(\n(\s*)id: FileEventScheduledFileKind\.oneShotTaskIDPrefix \+ base,\n\s*authority: authority\n\s*\)',
    s
)
assert m, 'one-shot remove self'
indent = m.group(1)
s = s[:m.start()] + (
    '_ = try registration.deleteSchedule(\n'
    '%sid: FileEventQueueLayout.taskID(forSubscription: base, kind: .oneShot),\n'
    '%sauthority: authority\n'
    '%s)' % (indent, indent, indent[:-4])
) + s[m.end():]
open(p, 'w').write(s)
print('ok')
