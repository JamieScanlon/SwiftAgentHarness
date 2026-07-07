//
//  Shared process-aware advisory flock helper (open → flock → inode verify).
//

import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let advisoryFlock: @convention(c) (Int32, Int32) -> Int32 = flock

enum AdvisoryProcessAwareWriteLockError: Error, Equatable {
    case timeout
    case flockFailed
}

struct AdvisoryProcessAwareWriteLockConfiguration: Sendable, Equatable {
    var timeoutMs: Int
    var watchdogIntervalMs: Int
    var maxHoldMs: Int
    var maxHoldGraceMs: Int
    var removeOnRelease: Bool
    var wireFormat: WireFormat

    enum WireFormat: Sendable, Equatable {
        case standard
        case sessionLegacy
    }

    static func sessionRegistryDefaults(timeoutMs: Int = 30_000) -> Self {
        Self(
            timeoutMs: timeoutMs,
            watchdogIntervalMs: 60_000,
            maxHoldMs: 300_000,
            maxHoldGraceMs: SessionPersistenceConfiguration.transcriptLockMaxHoldGraceMs,
            removeOnRelease: true,
            wireFormat: .sessionLegacy
        )
    }
}

struct AdvisoryProcessAwareLockPayload: Codable, Sendable, Equatable {
    var pid: Int32
    var startToken: UInt64
    var acquiredAtWall: Double
    var bootKey: String?

    static func decodeFlexible(from data: Data) -> AdvisoryProcessAwareLockPayload? {
        if let decoded = try? JSONDecoder().decode(AdvisoryProcessAwareLockPayload.self, from: data) {
            return decoded
        }
        struct SessionLegacyWire: Decodable {
            var pid: Int32
            var createdAt: Double
            var starttime: UInt64
            var bootKey: String?
        }
        guard let legacy = try? JSONDecoder().decode(SessionLegacyWire.self, from: data) else {
            return nil
        }
        return AdvisoryProcessAwareLockPayload(
            pid: legacy.pid,
            startToken: legacy.starttime,
            acquiredAtWall: legacy.createdAt,
            bootKey: legacy.bootKey
        )
    }

    func encode(config: AdvisoryProcessAwareWriteLockConfiguration) throws -> Data {
        switch config.wireFormat {
        case .standard:
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return try enc.encode(self)
        case .sessionLegacy:
            struct Wire: Encodable {
                var pid: Int32
                var createdAt: Double
                var starttime: UInt64
            }
            return try JSONEncoder().encode(
                Wire(pid: pid, createdAt: acquiredAtWall, starttime: startToken)
            )
        }
    }
}

/// Cross-process advisory write lock with process-aware stale recovery.
/// Use of @unchecked Sendable is valid here: one fd per instance; callers serialize acquire/release.
final class AdvisoryProcessAwareWriteLockFile: @unchecked Sendable {
    private let lockURL: URL
    private let removeOnRelease: Bool
    private var fd: Int32 = -1
    private var locked = false

    init(lockURL: URL, removeOnRelease: Bool) {
        self.lockURL = lockURL
        self.removeOnRelease = removeOnRelease
    }

    var openFileDescriptorForTesting: Int32 { fd }

    func acquire(config: AdvisoryProcessAwareWriteLockConfiguration) throws {
        let dir = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = lockURL.path
        let deadline = CFAbsoluteTimeGetCurrent() + Double(config.timeoutMs) / 1000.0
        let watchdogStep = min(
            max(Double(config.watchdogIntervalMs) / 1000.0, 0.05),
            1.0
        )
        var lastCheck = CFAbsoluteTimeGetCurrent()

        while true {
            if fd < 0 {
                let fdNew = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                guard fdNew >= 0 else { throw AdvisoryProcessAwareWriteLockError.flockFailed }
                fd = fdNew
            }

            let flockResult = advisoryFlock(fd, LOCK_EX | LOCK_NB)
            if flockResult == 0 {
                if Self.verifyOpenedFileMatchesPath(fd: fd, path: path) {
                    try writePayload(config: config)
                    locked = true
                    return
                }
                discardFd()
                continue
            }

            let blocking = (errno == EWOULDBLOCK || errno == EAGAIN)
            if !blocking {
                discardFd()
                throw AdvisoryProcessAwareWriteLockError.flockFailed
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastCheck >= watchdogStep {
                lastCheck = now
                let nowWall = Date().timeIntervalSince1970
                if let payload = Self.readPayload(lockURL: lockURL),
                   Self.shouldReapHolder(payload: payload, nowWall: nowWall, config: config) {
                    Self.reapLockFileIfPossible(lockURL: lockURL)
                    discardFd()
                    continue
                }
            }

            if now >= deadline {
                discardFd()
                throw AdvisoryProcessAwareWriteLockError.timeout
            }
            usleep(20_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        let fdToClose = fd
        let wasLocked = locked
        fd = -1
        locked = false

        if wasLocked {
            _ = ftruncate(fdToClose, 0)
        }
        _ = advisoryFlock(fdToClose, LOCK_UN)
        close(fdToClose)
        if removeOnRelease {
            try? FileManager.default.removeItem(at: lockURL)
        }
    }

    deinit {
        release()
    }

    static func verifyOpenedFileMatchesPath(fd: Int32, path: String) -> Bool {
        var pre = stat()
        guard lstat(path, &pre) == 0 else { return false }
        if (pre.st_mode & S_IFMT) == S_IFLNK { return false }
        if pre.st_nlink > 1 { return false }
        var post = stat()
        guard fstat(fd, &post) == 0 else { return false }
        return pre.st_ino == post.st_ino && pre.st_dev == post.st_dev
    }

    private static func readPayload(lockURL: URL) -> AdvisoryProcessAwareLockPayload? {
        guard let raw = try? Data(contentsOf: lockURL), !raw.isEmpty else { return nil }
        return AdvisoryProcessAwareLockPayload.decodeFlexible(from: raw)
    }

    static func shouldReapHolder(
        payload: AdvisoryProcessAwareLockPayload,
        nowWall: TimeInterval,
        config: AdvisoryProcessAwareWriteLockConfiguration
    ) -> Bool {
        let pid = payload.pid
        if pid <= 0 { return true }
        if !ProcessLockIdentity.isPidAlive(pid) { return true }
        let liveToken = ProcessLockIdentity.startToken(for: pid)
        if liveToken != payload.startToken { return true }
        if !payload.bootKey.isNilOrEmpty,
           payload.bootKey != ProcessLockIdentity.currentBootKey() {
            return true
        }
        let maxGraceMs = config.maxHoldMs + config.maxHoldGraceMs
        if nowWall - payload.acquiredAtWall >= Double(maxGraceMs) / 1000.0 {
            return true
        }
        return false
    }

    private static func reapLockFileIfPossible(lockURL: URL) {
        try? FileManager.default.removeItem(at: lockURL)
    }

    private func writePayload(config: AdvisoryProcessAwareWriteLockConfiguration) throws {
        let pid = getpid()
        let payload = AdvisoryProcessAwareLockPayload(
            pid: pid,
            startToken: ProcessLockIdentity.startToken(for: pid),
            acquiredAtWall: Date().timeIntervalSince1970,
            bootKey: ProcessLockIdentity.currentBootKey()
        )
        let data = try payload.encode(config: config)
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base, data.count)
        }
        fsync(fd)
    }

    private func discardFd() {
        guard fd >= 0 else { return }
        let fdToClose = fd
        fd = -1
        locked = false
        _ = advisoryFlock(fdToClose, LOCK_UN)
        close(fdToClose)
    }
}

enum AdvisoryProcessAwareWriteLock {
    static func withLock<T>(
        lockURL: URL,
        config: AdvisoryProcessAwareWriteLockConfiguration,
        operation: () throws -> T
    ) throws -> T {
        let lock = AdvisoryProcessAwareWriteLockFile(
            lockURL: lockURL,
            removeOnRelease: config.removeOnRelease
        )
        try lock.acquire(config: config)
        defer { lock.release() }
        return try operation()
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.isEmpty
        }
    }
}
