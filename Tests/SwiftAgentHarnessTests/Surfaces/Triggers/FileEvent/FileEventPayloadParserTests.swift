import Foundation
import Logging
import Testing
@testable import SwiftAgentHarness

@Suite("FileEventPayloadParser")
struct FileEventPayloadParserTests {
    @Test("parses valid JSON")
    func validJSON() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("ok.json")
        let payload = FileEventPayload(type: .immediate, text: "hello")
        try JSONEncoder().encode(payload).write(to: url)
        let parser = FileEventPayloadParser(logger: Logger(label: "test"), backoffMilliseconds: [1, 1, 1], sleep: { _ in })
        let result = await parser.parse(at: url)
        #expect(result == .parsed(payload))
    }

    @Test("skips after max retries on truncated JSON")
    func truncatedJSON() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("bad.json")
        try Data("{\"type\":\"immediate\"".utf8).write(to: url)
        let parser = FileEventPayloadParser(logger: Logger(label: "test"), backoffMilliseconds: [1, 1, 1], sleep: { _ in })
        let result = await parser.parse(at: url)
        #expect(result == .skipped)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-event-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
