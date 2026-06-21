import Foundation

#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum QueuedFileWriterError: Error, Equatable {
    case symlinkParent
    case unstableFile
    case hardlinkTarget
    case openFailed
}

public enum QueuedFileWriter {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var tailQueues: [String: [() throws -> Void]] = [:]

    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        tailQueues = [:]
    }

    public static func write(data: Data, to path: String) throws {
        try enqueue(path: path) {
            try safeWrite(data: data, to: path)
        }
    }

    public static func append(data: Data, to path: String) throws {
        try enqueue(path: path) {
            try safeAppend(data: data, to: path)
        }
    }

    private static func enqueue(path: String, operation: @escaping () throws -> Void) throws {
        let key = FilesystemCanonicalPath.resolve(path)
        lock.lock()
        tailQueues[key, default: []].append(operation)
        let shouldRun = tailQueues[key]?.count == 1
        lock.unlock()
        guard shouldRun else { return }
        while true {
            lock.lock()
            guard let next = tailQueues[key]?.first else {
                lock.unlock()
                break
            }
            lock.unlock()
            try next()
            lock.lock()
            tailQueues[key]?.removeFirst()
            if tailQueues[key]?.isEmpty == true {
                tailQueues[key] = nil
            }
            lock.unlock()
        }
    }

    private static func safeWrite(data: Data, to path: String) throws {
        let canonicalPath = FilesystemCanonicalPath.resolve(path)
        try assertNoSymlinkParents(canonicalPath)
        let dir = (canonicalPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let temp = (dir as NSString).appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: URL(fileURLWithPath: temp), options: .atomic)
        if FileManager.default.fileExists(atPath: canonicalPath) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: canonicalPath), withItemAt: URL(fileURLWithPath: temp))
        } else {
            try FileManager.default.moveItem(atPath: temp, toPath: canonicalPath)
        }
    }

    private static func safeAppend(data: Data, to path: String) throws {
        let canonicalPath = FilesystemCanonicalPath.resolve(path)
        try assertNoSymlinkParents(canonicalPath)
        let fd = open(canonicalPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw QueuedFileWriterError.openFailed }
        defer { close(fd) }
        try verifyStableOpenedFile(fd: fd, expectedPath: canonicalPath)
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
    }

    static func assertNoSymlinkParents(_ path: String) throws {
        var ancestor = (path as NSString).deletingLastPathComponent
        while !ancestor.isEmpty && ancestor != "/" {
            if isSymlink(ancestor) { throw QueuedFileWriterError.symlinkParent }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    static func verifyStableOpenedFile(fd: Int32, expectedPath: String) throws {
        var pre = stat()
        guard lstat(expectedPath, &pre) == 0 else { throw QueuedFileWriterError.unstableFile }
        if (pre.st_mode & S_IFMT) == S_IFLNK { throw QueuedFileWriterError.symlinkParent }
        if pre.st_nlink > 1 { throw QueuedFileWriterError.hardlinkTarget }
        var post = stat()
        guard fstat(fd, &post) == 0 else { throw QueuedFileWriterError.unstableFile }
        if pre.st_ino != post.st_ino || pre.st_dev != post.st_dev { throw QueuedFileWriterError.unstableFile }
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}
