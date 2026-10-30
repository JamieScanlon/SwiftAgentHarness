import Foundation
@testable import SwiftAgentHarness
import Testing

#if canImport(Darwin) || os(Linux)
@Suite("QueuedFileWriter (BUG-004)")
struct QueuedFileWriterTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-queued-file-writer-\(UUID().uuidString)", isDirectory: true)
    }

    /// Runs `work` unstructured so a caller that is never resumed fails the test (`nil`) instead of
    /// hanging the run: a structured child that never returns would block the test from finishing.
    private func outcome(
        within limit: Duration,
        _ work: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, any Error>? {
        let (stream, continuation) = AsyncStream<Result<Void, any Error>?>.makeStream()
        Task {
            do {
                try await work()
                continuation.yield(.success(()))
            } catch {
                continuation.yield(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(nil)
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next() ?? nil
        timer.cancel()
        continuation.finish()
        return first
    }

    @Test func failedWriteDoesNotWedgeQueue() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("target.txt")
        try Data("seed".utf8).write(to: fileURL)
        let hardlinkURL = dir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: fileURL, to: hardlinkURL)

        let path = fileURL.path
        let appendFinished = AsyncStream<Void>.makeStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { appendFinished.continuation.yield(()) }
                await #expect(throws: QueuedFileWriterError.hardlinkTarget) {
                    try await QueuedFileWriter.append(data: Data("blocked".utf8), to: path)
                }
            }
            group.addTask {
                var iterator = appendFinished.stream.makeAsyncIterator()
                _ = await iterator.next()
                try FileManager.default.removeItem(at: hardlinkURL)
                try await QueuedFileWriter.write(data: Data("recovered".utf8), to: path)
            }
            try await group.waitForAll()
        }

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "recovered")
    }

    @Test func callerReceivesOwnError() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("target.txt")
        try Data("seed".utf8).write(to: fileURL)
        let hardlinkURL = dir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: fileURL, to: hardlinkURL)

        let path = fileURL.path
        let appendFailed = AsyncStream<Void>.makeStream()

        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                defer { appendFailed.continuation.yield(()) }
                do {
                    try await QueuedFileWriter.append(data: Data("first".utf8), to: path)
                    return "unexpected-success"
                } catch QueuedFileWriterError.hardlinkTarget {
                    return "hardlink-error"
                }
            }
            group.addTask {
                var iterator = appendFailed.stream.makeAsyncIterator()
                _ = await iterator.next()
                try FileManager.default.removeItem(at: hardlinkURL)
                try await QueuedFileWriter.write(data: Data("second".utf8), to: path)
                return "write-ok"
            }
            var outcomes: [String] = []
            for try await outcome in group {
                outcomes.append(outcome)
            }
            #expect(outcomes.contains("hardlink-error"))
            #expect(outcomes.contains("write-ok"))
        }

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "second")
    }

    @Test func concurrentAppendsAreSerializedWithoutCorruption() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("append.txt")
        let path = fileURL.path
        let chunkCount = 32
        let chunk = Data(repeating: 0xAB, count: 256)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<chunkCount {
                group.addTask {
                    try await QueuedFileWriter.append(data: chunk, to: path)
                }
            }
            try await group.waitForAll()
        }

        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk.count == chunkCount * chunk.count)
        #expect(onDisk.allSatisfy { $0 == 0xAB })
    }

    @Test func everyQueuedWriteResumesItsCallerAcrossBusyPaths() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pathCount = 48
        let appendsPerPath = 16
        let paths = (0..<pathCount).map { dir.appendingPathComponent("file-\($0).txt").path }

        let outcome = await outcome(within: .seconds(30)) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for path in paths {
                    for _ in 0..<appendsPerPath {
                        group.addTask {
                            try await QueuedFileWriter.append(data: Data("x".utf8), to: path)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        let finished = try #require(outcome, "a queued write never resumed its caller")
        try finished.get()

        for path in paths {
            let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(onDisk.count == appendsPerPath)
        }
    }

    @Test func appendWritesAllBytes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("large.bin")
        let path = fileURL.path
        var payload = Data(count: 64 * 1024)
        for index in payload.indices {
            payload[index] = UInt8(index % 251)
        }

        try await QueuedFileWriter.append(data: payload, to: path)

        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk == payload)
    }
}
#endif
