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
    case writeFailed
}

public enum QueuedFileWriter {
    private static let coordinator = Coordinator()

    public static func resetForTesting() async {
        await coordinator.resetForTesting()
    }

    public static func write(data: Data, to path: String) async throws {
        try await coordinator.enqueue(path: path) {
            try safeWrite(data: data, to: path)
        }
    }

    public static func append(data: Data, to path: String) async throws {
        try await coordinator.enqueue(path: path) {
            try safeAppend(data: data, to: path)
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
        try writeAll(data: data, to: fd)
    }

    private static func writeAll(data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var totalWritten = 0
            let totalCount = buffer.count
            while totalWritten < totalCount {
                let written = posixWrite(
                    fd,
                    baseAddress.advanced(by: totalWritten),
                    totalCount - totalWritten
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw QueuedFileWriterError.writeFailed
                }
                if written == 0 {
                    throw QueuedFileWriterError.writeFailed
                }
                totalWritten += written
            }
        }
    }

    #if os(Linux)
    private static func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.write(fd, buffer, count)
    }
    #else
    private static func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.write(fd, buffer, count)
    }
    #endif

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

private actor Coordinator {
    struct PendingOp {
        let perform: @Sendable () throws -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private var queues: [String: [PendingOp]] = [:]
    private var draining: Set<String> = []

    func resetForTesting() {
        queues = [:]
        draining = []
    }

    func enqueue(path: String, perform: @Sendable @escaping () throws -> Void) async throws {
        let key = FilesystemCanonicalPath.resolve(path)
        try await withCheckedThrowingContinuation { continuation in
            queues[key, default: []].append(PendingOp(perform: perform, continuation: continuation))
            if draining.insert(key).inserted {
                Task { await drain(key: key) }
            }
        }
    }

    private func drain(key: String) async {
        defer { draining.remove(key) }
        while let op = queues[key]?.first {
            queues[key]?.removeFirst()
            if queues[key]?.isEmpty == true {
                queues[key] = nil
            }
            do {
                try op.perform()
                op.continuation.resume()
            } catch {
                op.continuation.resume(throwing: error)
            }
        }
    }
}
