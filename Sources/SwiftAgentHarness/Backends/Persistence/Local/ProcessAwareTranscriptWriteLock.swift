//
//  Advisory flock on `<conversationId>.jsonl.lock`; payload pid + starttime.
//

import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let sah_flock: @convention(c) (Int32, Int32) -> Int32 = flock

/// On-wire JSON (older files may omit `acquiredAtWall`).
struct TranscriptLockPayload: Codable, Sendable, Equatable {
    var pid: Int32
    var startToken: UInt64
    var bootKey: String
    /// Wall time when lock was acquired (for max-hold watchdog on wait path).
    var acquiredAtWall: Double?
}

private final class ReentryState: NSObject {
    var depth: Int
    let primary: ProcessAwareTranscriptWriteLock
    init(depth: Int, primary: ProcessAwareTranscriptWriteLock) {
        self.depth = depth
        self.primary = primary
    }
}

/// Process-aware exclusive lock for one conversation transcript (cross-process on local FS).
/// Use of @unchecked Sendable is valid here
final class ProcessAwareTranscriptWriteLock: TranscriptWriteLock, @unchecked Sendable {
    static let reentryThreadKey = "HarnessTranscriptReentry"

    static func isHeldOnCurrentThread(conversationID: UUID) -> Bool {
        let key = conversationID.uuidString
        guard let map = Thread.current.threadDictionary[reentryThreadKey] as? NSMutableDictionary else {
            return false
        }
        return map[key] != nil
    }

    let conversationID: UUID
    private(set) var acquiredAt: Date = Date()

    /// Internal access for re-entry shim (same instant as outer).
    fileprivate var acquiredAtInternal: Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acquiredAt
    }

    private let lockURL: URL
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var locked = false

    /// Acquire or return a re-entrant shim for the same conversation on this thread.
    static func acquireExclusive(
        conversationID: UUID,
        lockFileURL: URL,
        timeoutMs: Int,
        allowReentrant: Bool
    ) throws -> any TranscriptWriteLock {
        let key = conversationID.uuidString
        if let map = Thread.current.threadDictionary[reentryThreadKey] as? NSMutableDictionary,
           map[key] != nil,
           !TranscriptWriteLockHeldRegistry.isWriteLockHeld(conversationID: conversationID) {
            map.removeObject(forKey: key)
        }
        if let map = Thread.current.threadDictionary[reentryThreadKey] as? NSMutableDictionary,
           let st = map[key] as? ReentryState {
            guard allowReentrant else {
                throw SessionPersistenceError.unsupportedOperation(
                    "Transcript write lock already held for this conversation on this thread (allowReentrant=false)"
                )
            }
            st.depth += 1
            return ReentrantTranscriptWriteLockShim(
                conversationID: conversationID,
                acquiredAt: st.primary.acquiredAtInternal,
                onUnlock: {
                    st.depth -= 1
                }
            )
        }

        let mine = ProcessAwareTranscriptWriteLock(conversationID: conversationID, lockFileURL: lockFileURL)
        try mine.acquireFirstProcessLock(timeoutMs: timeoutMs)

        let map = (Thread.current.threadDictionary[reentryThreadKey] as? NSMutableDictionary) ?? {
            let m = NSMutableDictionary()
            Thread.current.threadDictionary[reentryThreadKey] = m
            return m
        }()
        map[key] = ReentryState(depth: 1, primary: mine)
        return mine
    }

    private init(conversationID: UUID, lockFileURL: URL) {
        self.conversationID = conversationID
        self.lockURL = lockFileURL
    }

    private func acquireFirstProcessLock(timeoutMs: Int) throws {
        let dir = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = lockURL.path
        let fdNew = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fdNew >= 0 else {
            throw SessionPersistenceError.unsupportedOperation("lock open \(path)")
        }
        fd = fdNew

        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutMs) / 1000.0
        let watchdogStep = min(
            max(Double(SessionPersistenceConfiguration.transcriptLockWatchdogIntervalMs) / 1000.0, 0.05),
            1.0
        )
        var lastCheck = CFAbsoluteTimeGetCurrent()

        while true {
            let r = sah_flock(fd, LOCK_EX | LOCK_NB)
            if r == 0 {
                break
            }
            let blocking = (errno == EWOULDBLOCK || errno == EAGAIN)
            if !blocking {
                discardFd()
                throw SessionPersistenceError.unsupportedOperation("flock errno \(errno)")
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastCheck >= watchdogStep {
                lastCheck = now
                let nowWall = Date().timeIntervalSince1970
                if let payload = Self.readPayload(lockURL: lockURL),
                   Self.shouldReapHolder(payload: payload, nowWall: nowWall) {
                    Self.reapLockFileIfPossible(lockURL: lockURL)
                    continue
                }
            }

            if now >= deadline {
                discardFd()
                throw SessionPersistenceError.lockTimeout(conversationID: conversationID, waitedMs: timeoutMs)
            }
            usleep(20_000)
        }

        let acquired = Date()
        stateLock.lock()
        acquiredAt = acquired
        stateLock.unlock()
        let pid = getpid()
        let token = ProcessLockIdentity.startToken(for: pid)
        let boot = ProcessLockIdentity.currentBootKey()
        let payload = TranscriptLockPayload(
            pid: pid,
            startToken: token,
            bootKey: boot,
            acquiredAtWall: acquiredAt.timeIntervalSince1970
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(payload) else {
            discardFd()
            throw SessionPersistenceError.unsupportedOperation("lock encode")
        }
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base, data.count)
        }
        fsync(fd)
        stateLock.lock()
        locked = true
        stateLock.unlock()
        TranscriptLockSignalRegistry.shared.register(self)
        TranscriptWriteLockHeldRegistry.incrementHeld(conversationID: conversationID)
    }

    private static func readPayload(lockURL: URL) -> TranscriptLockPayload? {
        guard let raw = try? Data(contentsOf: lockURL), !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(TranscriptLockPayload.self, from: raw)
    }

    private static func shouldReapHolder(payload: TranscriptLockPayload, nowWall: TimeInterval) -> Bool {
        let pid = payload.pid
        if pid <= 0 { return true }
        if !ProcessLockIdentity.isPidAlive(pid) { return true }
        let liveToken = ProcessLockIdentity.startToken(for: pid)
        if liveToken != payload.startToken { return true }
        if let acquired = payload.acquiredAtWall {
            let maxGraceMs =
                SessionPersistenceConfiguration.transcriptLockMaxHoldMs
                + SessionPersistenceConfiguration.transcriptLockMaxHoldGraceMs
            if nowWall - acquired >= Double(maxGraceMs) / 1000.0 {
                return true
            }
        }
        return false
    }

    private static func reapLockFileIfPossible(lockURL: URL) {
        try? FileManager.default.removeItem(at: lockURL)
    }

    func unlock() {
        let key = conversationID.uuidString
        if let map = Thread.current.threadDictionary[Self.reentryThreadKey] as? NSMutableDictionary,
           let st = map[key] as? ReentryState, st.primary === self {
            if st.depth != 1 {
                assertionFailure("Release nested transcript write locks (re-entrant shim) before the outer lock")
                return
            }
            map.removeObject(forKey: key)
        }

        stateLock.lock()
        guard fd >= 0 else {
            locked = false
            stateLock.unlock()
            return
        }
        let fdToClose = fd
        let wasLocked = locked
        fd = -1
        locked = false
        stateLock.unlock()

        TranscriptLockSignalRegistry.shared.unregister(self)
        if wasLocked {
            TranscriptWriteLockHeldRegistry.decrementHeld(conversationID: conversationID)
        }
        if wasLocked {
            _ = ftruncate(fdToClose, 0)
        }
        _ = sah_flock(fdToClose, LOCK_UN)
        close(fdToClose)
    }

    /// Same as ``unlock`` but named for shutdown path documentation.
    func unlockFromShutdownPath() {
        unlock()
    }

    private func discardFd() {
        stateLock.lock()
        guard fd >= 0 else {
            locked = false
            stateLock.unlock()
            return
        }
        let fdToClose = fd
        fd = -1
        locked = false
        stateLock.unlock()

        TranscriptLockSignalRegistry.shared.unregister(self)
        _ = sah_flock(fdToClose, LOCK_UN)
        close(fdToClose)
    }

    deinit {
        stateLock.lock()
        guard fd >= 0 else {
            locked = false
            stateLock.unlock()
            return
        }
        let fdToClose = fd
        let wasLocked = locked
        fd = -1
        locked = false
        stateLock.unlock()

        if wasLocked {
            TranscriptWriteLockHeldRegistry.decrementHeld(conversationID: conversationID)
        }
        TranscriptLockSignalRegistry.shared.unregister(self)
        _ = sah_flock(fdToClose, LOCK_UN)
        close(fdToClose)
    }
}

// MARK: - Re-entrant shim (same thread, opt-in)

private final class ReentrantTranscriptWriteLockShim: TranscriptWriteLock {
    let conversationID: UUID
    let acquiredAt: Date
    private let onUnlock: () -> Void
    private var released = false

    init(conversationID: UUID, acquiredAt: Date, onUnlock: @escaping () -> Void) {
        self.conversationID = conversationID
        self.acquiredAt = acquiredAt
        self.onUnlock = onUnlock
    }

    func unlock() {
        guard !released else { return }
        released = true
        onUnlock()
    }
}
