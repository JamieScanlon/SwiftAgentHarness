import Darwin
import Foundation

enum MemoryFileLockError: Error, Equatable {
    case flockFailed(Int32)
    case atomicReplaceFailed
}

/// Result box for `withLockAsync` (cannot nest types inside generic closures).
/// `@unchecked Sendable`: mutated only while the owning lock thread waits on the semaphore;
/// the Task writes `result` then signals, so the waiter observes a happens-before.
private final class MemoryFileLockAsyncBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum MemoryFileLock {
    /// Acquires an exclusive advisory lock on `.memory.lock` under `memoryDirectory`.
    /// Uses blocking `LOCK_EX`; acceptable for cooperative-thread writes at current memory file sizes.
    /// Not reentrant: nested `withLock` on the same directory deadlocks.
    static func withLock<T>(
        memoryDirectory: URL,
        fileManager: FileManager = .default,
        operation: () throws -> T
    ) throws -> T {
        try fileManager.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        let lockURL = memoryDirectory.appendingPathComponent(".memory.lock")
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: lockURL)
        defer {
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        if flock(handle.fileDescriptor, LOCK_EX) == -1 {
            throw MemoryFileLockError.flockFailed(errno)
        }
        return try operation()
    }

    /// Holds `.memory.lock` on a background thread while an async operation runs (e.g. FS bridge writes).
    static func withLockAsync<T: Sendable>(
        memoryDirectory: URL,
        fileManager: FileManager = .default,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value: T = try withLock(memoryDirectory: memoryDirectory, fileManager: fileManager) {
                        let sem = DispatchSemaphore(value: 0)
                        let box = MemoryFileLockAsyncBox<T>()
                        Task {
                            do {
                                box.result = .success(try await operation())
                            } catch {
                                box.result = .failure(error)
                            }
                            sem.signal()
                        }
                        sem.wait()
                        switch box.result! {
                        case .success(let value):
                            return value
                        case .failure(let error):
                            throw error
                        }
                    }
                    cont.resume(returning: value)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func atomicWrite(data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(url.lastPathComponent)")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    static func atomicWrite(text: String, to url: URL, fileManager: FileManager = .default) throws {
        try atomicWrite(data: Data(text.utf8), to: url, fileManager: fileManager)
    }
}
