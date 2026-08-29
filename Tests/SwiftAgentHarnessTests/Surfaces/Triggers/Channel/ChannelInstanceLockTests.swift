import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("ChannelInstanceLock")
struct ChannelInstanceLockTests {
    @Test("acquire and release")
    func acquireRelease() throws {
        let dir = try tempDir()
        let acquired = try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
        #expect(acquired == true)
        try ChannelInstanceLock.release(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
    }

    /// Re-entrant within one process. The rule used to be "same platform identity re-acquires",
    /// which is a different and much weaker claim — see `foreignLiveProcessIsRefused`.
    @Test("same process re-acquire succeeds")
    func sameProcessReacquire() throws {
        let dir = try tempDir()
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == true)
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == true)
    }

    /// A lock held by a *different live process* with the same identity string.
    ///
    /// This is the defect the spec calls fail-fatal: the identity is `channel:platformIdentity`,
    /// entirely config-derived, so two gateways running the same bot both matched it and both
    /// believed they had acquired. Only one socket receives each platform event, so the loser
    /// silently dropped messages rather than reporting contention.
    ///
    /// The parent process stands in for the other gateway: alive, same uid so `kill(pid, 0)` can
    /// actually see it, and never us. PID 1 does not work — it is root-owned, so `kill` returns
    /// `EPERM` for a normal user and the holder reads as *dead*, which sends the fixture down the
    /// stale-reclaim path without ever reaching the code under test.
    @Test("a lock held by another live process is refused")
    func foreignLiveProcessIsRefused() throws {
        let dir = try tempDir()
        let lockURL = ChannelInstanceLock.lockURL(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = SchedulerLockState(
            ownerPID: getppid(),
            ownerStartToken: 0,
            bootKey: "",
            identity: "slack:bot-1",
            acquiredAt: Date()
        )
        try JSONEncoder().encode(foreign).write(to: lockURL)
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == false)
        // Not overwritten on refusal — this is what lets `start()` surface the real owner's pid.
        #expect(try ChannelInstanceLock.readOwnerPID(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == getppid())
    }

    /// The other half of the same defect: the loser's `stop()` deleted the real owner's lock file,
    /// because its in-memory `ownsLock` flag was set by the acquire that wrongly succeeded.
    @Test("releasing a lock this process does not own leaves the file alone")
    func releaseByNonOwnerIsRefused() throws {
        let dir = try tempDir()
        let lockURL = ChannelInstanceLock.lockURL(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = SchedulerLockState(
            ownerPID: getppid(),
            ownerStartToken: 0,
            bootKey: "",
            identity: "slack:bot-1",
            acquiredAt: Date()
        )
        try JSONEncoder().encode(foreign).write(to: lockURL)
        try ChannelInstanceLock.release(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
    }

    /// The cron scheduler shares `SchedulerLock` and must keep its identity-only semantics — a
    /// process-scoped default would have changed behaviour it never asked for. Same fixture as
    /// `foreignLiveProcessIsRefused`, opposite expectation: unscoped, a live foreign holder with a
    /// matching identity still satisfies the lock.
    @Test("the scheduler path is unaffected by process scoping")
    func schedulerPathKeepsIdentitySemantics() throws {
        let dir = try tempDir()
        let lockURL = dir.appendingPathComponent("scheduler.lock")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = SchedulerLockState(
            ownerPID: getppid(),
            ownerStartToken: 0,
            bootKey: "",
            identity: "owner",
            acquiredAt: Date()
        )
        try JSONEncoder().encode(foreign).write(to: lockURL)
        #expect(try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "owner") == true)
        #expect(try SchedulerLock.tryAcquire(lockURL: lockURL, identity: "other") == false)
    }

    @Test("stale channel lock reclaimed when start token mismatches")
    func staleLockReclaimed() throws {
        let dir = try tempDir()
        let lockURL = ChannelInstanceLock.lockURL(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1")
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let stale = SchedulerLockState(
            ownerPID: pid,
            ownerStartToken: ProcessLockIdentity.startToken(for: pid) &+ 777,
            bootKey: ProcessLockIdentity.currentBootKey(),
            identity: "slack:bot-1",
            acquiredAt: Date()
        )
        try JSONEncoder().encode(stale).write(to: lockURL)
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == true)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("channel-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
