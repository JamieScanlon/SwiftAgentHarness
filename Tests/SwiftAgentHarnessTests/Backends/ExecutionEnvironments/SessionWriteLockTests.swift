import Foundation
@testable import SwiftAgentHarness
import Testing

#if canImport(Darwin)
import Darwin
#endif

@Suite("Session write lock (SEC-004)")
struct SessionWriteLockTests {
    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-session-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sandbox-registry.lock")
    }

    #if canImport(Darwin) || os(Linux)
    @Test func payloadIncludesProcessStartToken() throws {
        let lockURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        let lock = SessionWriteLockFile(lockURL: lockURL)
        try lock.acquire(timeoutMs: 5_000)
        defer { lock.release() }

        let data = try Data(contentsOf: lockURL)
        let payload = try JSONDecoder().decode(SessionWriteLockPayload.self, from: data)
        #expect(payload.pid == getpid())
        #expect(payload.starttime != 0)
        #expect(payload.starttime == ProcessLockIdentity.startToken(for: payload.pid))
    }
    #endif

    @Test func writePayloadTruncatesPreviousContent() throws {
        let lockURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let garbage = Data(repeating: 0x41, count: 4096)
        try garbage.write(to: lockURL)

        let lock = SessionWriteLockFile(lockURL: lockURL)
        try lock.acquire(timeoutMs: 5_000)
        defer { lock.release() }

        let onDisk = try Data(contentsOf: lockURL)
        let payload = try JSONDecoder().decode(SessionWriteLockPayload.self, from: onDisk)
        let expected = try JSONEncoder().encode(payload)
        #expect(onDisk.count == expected.count)
    }

    @Test func shouldReapHolderWhenMaxHoldExceeded() {
        let config = AdvisoryProcessAwareWriteLockConfiguration(
            timeoutMs: 5_000,
            watchdogIntervalMs: 50,
            maxHoldMs: 100,
            maxHoldGraceMs: 50,
            removeOnRelease: true,
            wireFormat: .sessionLegacy
        )
        let pid = getpid()
        let payload = AdvisoryProcessAwareLockPayload(
            pid: pid,
            startToken: ProcessLockIdentity.startToken(for: pid),
            acquiredAtWall: Date().timeIntervalSince1970 - 1.0,
            bootKey: ProcessLockIdentity.currentBootKey()
        )
        let shouldReap = AdvisoryProcessAwareWriteLockFile.shouldReapHolder(
            payload: payload,
            nowWall: Date().timeIntervalSince1970,
            config: config
        )
        #expect(shouldReap)
    }

    @Test func acquireAfterSyntheticStalePayload() throws {
        let lockURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stale = SessionWriteLockPayload(
            pid: 1,
            createdAt: Date().timeIntervalSince1970 - 10_000,
            starttime: 123
        )
        try JSONEncoder().encode(stale).write(to: lockURL)

        try SessionWriteLock.withLock(lockURL: lockURL, timeoutMs: 5_000) {
            let data = try Data(contentsOf: lockURL)
            let payload = try JSONDecoder().decode(SessionWriteLockPayload.self, from: data)
            #expect(payload.pid == getpid())
        }
    }

    #if canImport(Darwin)
    @Test func acquiredLockInodeMatchesPath() throws {
        let lockURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        let lock = SessionWriteLockFile(lockURL: lockURL)
        try lock.acquire(timeoutMs: 5_000)
        defer { lock.release() }

        let fd = lock.openFileDescriptorForTesting
        #expect(fd >= 0)
        #expect(
            AdvisoryProcessAwareWriteLockFile.verifyOpenedFileMatchesPath(
                fd: fd,
                path: lockURL.path
            )
        )
    }
    #endif

    @Test func withLockSerializesConcurrentWriters() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-session-lock-excl-\(UUID().uuidString)", isDirectory: true)
        let lockURL = dir.appendingPathComponent("sandbox-registry.lock")
        let target = dir.appendingPathComponent("counter.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "0".write(to: target, atomically: true, encoding: .utf8)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? SessionWriteLock.withLock(lockURL: lockURL, timeoutMs: 10_000) {
                        let raw = (try? String(contentsOf: target, encoding: .utf8)) ?? "0"
                        let value = (Int(raw) ?? 0) + 1
                        try? String(value).write(to: target, atomically: true, encoding: .utf8)
                    }
                }
            }
        }

        let final = try String(contentsOf: target, encoding: .utf8)
        #expect(final == "8")
    }

    #if canImport(Darwin)
    @Test func lockTimeoutWhenExternallyFlocked() throws {
        let lockURL = tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let holderFd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(holderFd >= 0)
        defer { close(holderFd) }

        let flockFn: @convention(c) (Int32, Int32) -> Int32 = flock
        #expect(flockFn(holderFd, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flockFn(holderFd, LOCK_UN) }

        var caught: SessionWriteLockError?
        do {
            try SessionWriteLock.withLock(lockURL: lockURL, timeoutMs: 150) {}
        } catch let error as SessionWriteLockError {
            caught = error
        }
        #expect(caught == .timeout)
    }
    #endif
}
