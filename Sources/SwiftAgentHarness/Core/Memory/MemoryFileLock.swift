import Darwin
import Foundation

enum MemoryFileLockError: Error, Equatable {
    case flockFailed(Int32)
    case atomicReplaceFailed
}

enum MemoryFileLock {
    /// Acquires an exclusive advisory lock on `.memory.lock` under `memoryDirectory`.
    /// Uses blocking `LOCK_EX`; acceptable for cooperative-thread writes at current memory file sizes.
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
