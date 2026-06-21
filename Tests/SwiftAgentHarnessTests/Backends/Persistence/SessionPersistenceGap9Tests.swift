import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("Harness session persistence Gap 9 (JSONL header / entry type versioning)")
struct SessionPersistenceGap9Tests {
    private func encodedEntryLine(type: String = "message", sequence: Int = 1) throws -> String {
        let line = SessionJSONLTranscriptBodyLine(
            sequence: sequence,
            id: SessionEntryID.generate().rawValue,
            parentId: nil,
            type: type,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            payloadJSON: "{}"
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(line)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func parseTranscriptV1HeaderAndEntries() throws {
        let cid = UUID()
        let header = #"{"id":"\#(cid.uuidString)","timestamp":"2020-01-01T00:00:00Z","type":"session","version":1}"#
        let body = try encodedEntryLine()
        let text = header + "\n" + body + "\n"
        let parsed = try SessionJSONLTranscriptReader.parseTranscript(from: text)
        #expect(parsed.header.version == 1)
        #expect(parsed.header.id == cid.uuidString)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries[0].type == .message)
    }

    @Test func parseTranscriptV2HeaderWithCwd() throws {
        let cid = UUID()
        let header =
            #"{"cwd":"/tmp/demo","id":"\#(cid.uuidString)","timestamp":"2020-01-02T00:00:00Z","type":"session","version":2}"#
        let body = try encodedEntryLine()
        let text = header + "\n" + body
        let parsed = try SessionJSONLTranscriptReader.parseTranscript(from: text)
        #expect(parsed.header.version == 2)
        #expect(parsed.header.cwd == "/tmp/demo")
        #expect(parsed.entries.count == 1)
    }

    @Test func legacyBranchSummaryTypeNormalizesForV1AndV2Headers() throws {
        let cid = UUID()
        let body = try encodedEntryLine(type: "branchSummary")
        for hdrVersion in 1 ... 2 {
            let header =
                #"{"id":"\#(cid.uuidString)","timestamp":"2020-01-01T00:00:00Z","type":"session","version":\#(hdrVersion)}"#
            let parsed = try SessionJSONLTranscriptReader.parseTranscript(from: header + "\n" + body)
            let entry = try #require(parsed.entries.first)
            #expect(entry.type == .branchSummary)
            #expect(entry.harnessTypeRaw == nil)
        }
    }

    @Test func unsupportedHeaderVersionThrows() throws {
        let cid = UUID()
        let header = #"{"id":"\#(cid.uuidString)","timestamp":"2020-01-01T00:00:00Z","type":"session","version":99}"#
        let body = try encodedEntryLine()
        #expect(throws: SessionJSONLTranscriptReaderError.invalidHeader) {
            try SessionJSONLTranscriptReader.parseTranscript(from: header + "\n" + body)
        }
    }

    @Test func zeroHeaderVersionThrows() throws {
        let cid = UUID()
        let header = #"{"id":"\#(cid.uuidString)","timestamp":"2020-01-01T00:00:00Z","type":"session","version":0}"#
        #expect(throws: SessionJSONLTranscriptReaderError.invalidHeader) {
            try SessionJSONLTranscriptReader.parseTranscript(from: header)
        }
    }

    @Test func nonSessionHeaderTypeThrows() throws {
        let header = #"{"id":"x","timestamp":"2020-01-01T00:00:00Z","type":"conversation","version":2}"#
        #expect(throws: SessionJSONLTranscriptReaderError.invalidHeader) {
            try SessionJSONLTranscriptReader.parseTranscript(from: header)
        }
    }

    @Test func parseEntryLinesWhitespaceOnlyReturnsEmpty() throws {
        let entries = try SessionJSONLTranscriptReader.parseEntryLines(from: "  \n\t\n  ")
        #expect(entries.isEmpty)
    }

    @Test func loadEntriesMissingFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).jsonl")
        #expect(throws: SessionJSONLTranscriptReaderError.self) {
            try SessionJSONLTranscriptReader.loadEntries(fileURL: url)
        }
    }

    @Test func parseTranscriptIsIdempotent() throws {
        let cid = UUID()
        let header = #"{"id":"\#(cid.uuidString)","timestamp":"2020-01-01T00:00:00Z","type":"session","version":2}"#
        let body1 = try encodedEntryLine()
        let body2 = try encodedEntryLine(sequence: 2)
        let text = header + "\n" + body1 + "\n" + body2
        let a = try SessionJSONLTranscriptReader.parseTranscript(from: text)
        let b = try SessionJSONLTranscriptReader.parseTranscript(from: text)
        #expect(a == b)
        #expect(a.entries.count == 2)
    }

    @Test func writeFreshHeaderRoundTripMatchesCurrentWriteVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap9-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        try SessionJSONLTranscriptWriter(fileURL: url).writeFreshHeader(conversationId: cid)
        let parsed = try SessionJSONLTranscriptReader.loadParsed(fileURL: url)
        #expect(parsed.header.version == SessionJSONLTranscriptFormat.currentWriteHeaderVersion)
        #expect(parsed.header.type == "session")
        #expect(parsed.header.id == cid.uuidString)
        #expect(parsed.entries.isEmpty)
    }

    @Test func appendEntryRoundTripPreservesEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sah-gap9-rt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        let fileWriter = SessionJSONLTranscriptWriter(fileURL: url)
        try fileWriter.writeFreshHeader(conversationId: cid)
        let entry = SessionTranscriptEntry(
            sequence: 1,
            entryId: .generate(),
            parentEntryId: nil,
            type: .system,
            harnessTypeRaw: nil,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            payloadJSON: #"{"ok":true}"#
        )
        try fileWriter.appendEntryLine(try SessionJSONLTranscriptCodec.jsonlData(for: entry))
        let parsed = try SessionJSONLTranscriptReader.loadParsed(fileURL: url)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries[0] == entry)
    }
}
