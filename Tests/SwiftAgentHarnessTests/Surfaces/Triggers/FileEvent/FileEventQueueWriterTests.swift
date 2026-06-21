import Foundation
import os
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventQueueWriter")
struct FileEventQueueWriterTests {
    @Test("writes trust sidecar before event json")
    func trustBeforeJson() throws {
        let dir = try makeTempDir()
        let phases = OSAllocatedUnfairLock(initialState: [String]())
        try FileEventQueueWriter.writeImmediate(
            eventsDirectory: dir,
            basename: "evt",
            text: "hello",
            trust: FileEventTrustSidecar(trust: .knownParty, source: "webhook"),
            recordWritePhase: { phase in
                phases.withLock { $0.append(phase) }
            }
        )
        #expect(phases.withLock { $0 } == ["trust", "json"])
        let jsonURL = dir.appendingPathComponent("evt.json")
        let trustURL = FileEventQueueLayout.trustSidecarURL(for: jsonURL)
        #expect(FileManager.default.fileExists(atPath: trustURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let decoded = try JSONDecoder().decode(FileEventTrustSidecar.self, from: Data(contentsOf: trustURL))
        #expect(decoded.trust == .knownParty)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
