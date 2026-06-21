import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    public static let defaultStaleMs = 60_000
    public static let defaultMaxHoldMs = 300_000

    private let lockURL: URL
    private var fd: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    public func acquire(timeoutMs: Int = 30_000, staleMs: Int = defaultStaleMs) throws {
        let dir = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw SessionWriteLockError.flockFailed }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try writePayload()
                return
            }
            if try isStale(staleMs: staleMs) {
                _ = flock(fd, LOCK_UN)
                try? FileManager.default.removeItem(at: lockURL)
                fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SessionWriteLockError.timeout
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        try? FileManager.default.removeItem(at: lockURL)
    }

    deinit { release() }

    private func writePayload() throws {
        let payload = SessionWriteLockPayload(pid: getpid(), createdAt: Date().timeIntervalSince1970, starttime: 0)
        let data = try JSONEncoder().encode(payload)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func isStale(staleMs: Int) throws -> Bool {
        guard let data = try? Data(contentsOf: lockURL),
              let payload = try? JSONDecoder().decode(SessionWriteLockPayload.self, from: data) else {
            return true
        }
        let ageMs = (Date().timeIntervalSince1970 - payload.createdAt) * 1000
        if ageMs > Double(staleMs) { return true }
        return kill(payload.pid, 0) != 0 && errno == ESRCH
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
