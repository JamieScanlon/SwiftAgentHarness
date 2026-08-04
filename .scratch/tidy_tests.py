import re

p = 'Tests/SwiftAgentHarnessTests/Surfaces/Triggers/FileEvent/FileEventSubscriptionWriterTests.swift'
s = open(p).read()

s = s.replace('import Foundation\nimport Testing', 'import Foundation\nimport os\nimport Testing')

old = '''        let phases = PhaseRecorder()
        try FileEventQueueWriter.writeSubscription(
            eventsDirectory: directory,
            basename: "ordered",
            kind: .periodic,
            text: "x",
            schedule: "0 * * * *",
            trust: FileEventTrustSidecar(),
            recordWritePhase: { phases.record($0) }
        )
        #expect(phases.phases == ["trust", "json"])'''
new = '''        // Same idiom as `FileEventQueueWriterTests.trustBeforeJson`, which asserts this invariant
        // for the queue half.
        let phases = OSAllocatedUnfairLock(initialState: [String]())
        try FileEventQueueWriter.writeSubscription(
            eventsDirectory: directory,
            basename: "ordered",
            kind: .periodic,
            text: "x",
            schedule: "0 * * * *",
            trust: FileEventTrustSidecar(),
            recordWritePhase: { phase in phases.withLock { $0.append(phase) } }
        )
        #expect(phases.withLock { $0 } == ["trust", "json"])'''
assert s.count(old) == 1, 'phase anchor %d' % s.count(old)
s = s.replace(old, new)

# Drop the now-redundant helper type.
m = re.search(
    r'\n/// Ordered record of the writer\'s phases\.(?:.|\n)*?\n\}\n$',
    s
)
assert m, 'recorder block'
s = s[:m.start()] + '\n'
open(p, 'w').write(s)
print('ok')
