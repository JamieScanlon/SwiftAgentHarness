import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("TriggerScheduler")
struct TriggerSchedulerTests {
    @Test("scheduler lock acquire and release")
    func lockRoundTrip() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("sched-lock-\(UUID().uuidString).json")
        let acquired = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "test")
        #expect(acquired == true)
        try SchedulerLock.release(lockURL: lockURL, identity: "test")
    }

    @Test("stale lock reclaimed when start token mismatches")
    func staleLockReclaimedOnStartTokenMismatch() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("sched-lock-\(UUID().uuidString).json")
        let pid = ProcessInfo.processInfo.processIdentifier
        let stale = SchedulerLockState(
            ownerPID: pid,
            ownerStartToken: ProcessLockIdentity.startToken(for: pid) &+ 999,
            bootKey: ProcessLockIdentity.currentBootKey(),
            identity: "other",
            acquiredAt: Date()
        )
        try JSONEncoder().encode(stale).write(to: lockURL)
        let acquired = try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "test")
        #expect(acquired == true)
        let state = try SchedulerLock.read(lockURL: lockURL)
        #expect(state?.identity == "test")
    }

    @Test("same identity re-acquire succeeds while holder alive")
    func sameIdentityReacquire() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("sched-lock-\(UUID().uuidString).json")
        #expect(try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "owner") == true)
        #expect(try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "owner") == true)
        #expect(try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "other") == false)
    }

    @Test("task store persists round trip")
    func taskStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).json")
        let store = ScheduledTaskStore(fileURL: url)
        let task = ScheduledTask(
            schedule: ScheduledTaskSchedule(kind: .at, at: "2030-06-01T12:00:00Z"),
            payloadKind: .agentTurn,
            payloadText: "remind me",
            recurring: false
        )
        _ = try TriggerRegistrationTestSupport.register(task, into: store)
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == task.id)
    }
}
