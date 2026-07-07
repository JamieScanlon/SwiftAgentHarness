import Foundation

public enum SessionWriteLockError: Error, Equatable {
    case timeout
    case flockFailed
}

public struct SessionWriteLockPayload: Codable, Sendable, Equatable {
    public var pid: Int32
    public var createdAt: Double
    public var starttime: UInt64

    public init(pid: Int32, createdAt: Double, starttime: UInt64) {
        self.pid = pid
        self.createdAt = createdAt
        self.starttime = starttime
    }
}

public final class SessionWriteLockFile: @unchecked Sendable {
    /// Watchdog poll interval while blocked on acquire (not a stale-after threshold).
    public static let defaultWatchdogIntervalMs = 60_000
    public static let defaultMaxHoldMs = 300_000
    public static let defaultMaxHoldGraceMs = 30_000

    private let backing: AdvisoryProcessAwareWriteLockFile

    public init(lockURL: URL) {
        backing = AdvisoryProcessAwareWriteLockFile(lockURL: lockURL, removeOnRelease: true)
    }

    var openFileDescriptorForTesting: Int32 { backing.openFileDescriptorForTesting }

    public func acquire(
        timeoutMs: Int = 30_000,
        watchdogIntervalMs: Int = defaultWatchdogIntervalMs,
        maxHoldMs: Int = defaultMaxHoldMs,
        maxHoldGraceMs: Int = defaultMaxHoldGraceMs
    ) throws {
        let config = AdvisoryProcessAwareWriteLockConfiguration(
            timeoutMs: timeoutMs,
            watchdogIntervalMs: watchdogIntervalMs,
            maxHoldMs: maxHoldMs,
            maxHoldGraceMs: maxHoldGraceMs,
            removeOnRelease: true,
            wireFormat: .sessionLegacy
        )
        do {
            try backing.acquire(config: config)
        } catch AdvisoryProcessAwareWriteLockError.timeout {
            throw SessionWriteLockError.timeout
        } catch AdvisoryProcessAwareWriteLockError.flockFailed {
            throw SessionWriteLockError.flockFailed
        }
    }

    public func release() {
        backing.release()
    }
}

public enum SessionWriteLock {
    public static func withLock<T>(
        lockURL: URL,
        timeoutMs: Int = 30_000,
        operation: () throws -> T
    ) throws -> T {
        let lock = SessionWriteLockFile(lockURL: lockURL)
        try lock.acquire(timeoutMs: timeoutMs)
        defer { lock.release() }
        return try operation()
    }
}
