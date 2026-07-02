import Foundation
@testable import SwiftAgentHarness
import Testing

#if canImport(Darwin) || os(Linux)
@Suite("QueuedFileWriter (BUG-004)", .serialized)
struct QueuedFileWriterTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sah-queued-file-writer-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func failedWriteDoesNotWedgeQueue() async throws {
        await QueuedFileWriter.resetForTesting()
        defer { Task { await QueuedFileWriter.resetForTesting() } }

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("target.txt")
        try Data("seed".utf8).write(to: fileURL)
        let hardlinkURL = dir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: fileURL, to: hardlinkURL)

        let path = fileURL.path

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await #expect(throws: QueuedFileWriterError.hardlinkTarget) {
                    try await QueuedFileWriter.append(data: Data("blocked".utf8), to: path)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 100_000)
                try FileManager.default.removeItem(at: hardlinkURL)
                try await QueuedFileWriter.write(data: Data("recovered".utf8), to: path)
            }
            try await group.waitForAll()
        }

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == "recovered")
    }

    @Test func callerReceivesOwnError() async throws {
        await QueuedFileWriter.resetForTesting()
        defer { Task { await QueuedFileWriter.resetForTesting() } }

        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("target.txt")
        try Data("seed".utf8).write(to: fileURL)
        let hardlinkURL = dir.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: fileURL, to: hardlinkURL)

        let path = fileURL.path

        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    try await QueuedFileWriter.append(data: Data("first".utf8), to: path)
                    return "unexpected-success"
                } catch QueuedFileWriterError.hardlinkTarget {
                    return "hardlink-error"
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 100_000)
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
        await QueuedFileWriter.resetForTesting()
        defer { Task { await QueuedFileWriter.resetForTesting() } }

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

    @Test func appendWritesAllBytes() async throws {
        await QueuedFileWriter.resetForTesting()
        defer { Task { await QueuedFileWriter.resetForTesting() } }

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
