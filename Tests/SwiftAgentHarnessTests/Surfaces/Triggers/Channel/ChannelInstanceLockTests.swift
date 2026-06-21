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

    @Test("same platform identity re-acquire succeeds")
    func sameIdentityReacquire() throws {
        let dir = try tempDir()
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == true)
        #expect(try ChannelInstanceLock.tryAcquire(dataDirectory: dir, channel: .slack, platformIdentity: "bot-1") == true)
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
