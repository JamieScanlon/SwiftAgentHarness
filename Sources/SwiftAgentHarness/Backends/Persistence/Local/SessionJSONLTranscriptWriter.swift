//
//  Append-mostly JSONL transcript (harness spec); paired with ``SQLiteSessionCatalog`` for index/search.
//

import Foundation

/// Versioned session header (line 1); subsequent lines are `Entry` JSON objects.
struct SessionJSONLHeader: Codable, Sendable, Equatable {
    var type: String = "session"
    var version: Int = SessionJSONLTranscriptFormat.currentWriteHeaderVersion
    var id: String
    var timestamp: String
    var cwd: String?
}

enum SessionJSONLTranscriptWriterError: Error, Sendable, Equatable {
    case encodingFailed
    case transcriptFileOpenFailed
    case transcriptFileMissing
    case transcriptTruncateInvalid
}

final class SessionJSONLTranscriptWriter {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func writeFreshHeader(conversationId: UUID) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let header = SessionJSONLHeader(
            version: SessionJSONLTranscriptFormat.currentWriteHeaderVersion,
            id: conversationId.uuidString,
            timestamp: iso.string(from: Date()),
            cwd: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(header) else {
            throw SessionJSONLTranscriptWriterError.encodingFailed
        }
        try writeAtomically(Data(data + [0x0A]))
    }

    /// Append one JSON line (caller holds durability ordering vs catalog).
    func appendEntryLine(_ jsonLine: Data) throws {
        var line = jsonLine
        if line.last != 0x0A {
            line.append(0x0A)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw SessionJSONLTranscriptWriterError.transcriptFileOpenFailed
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Replaces one body line by ``SessionEntryID``; other lines are copied verbatim.
    static func replaceBodyEntry(
        fileURL: URL,
        conversationID: UUID,
        entryId: SessionEntryID,
        entry: SessionTranscriptEntry
    ) throws {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw SessionJSONLTranscriptWriterError.transcriptTruncateInvalid
        }
        var out: [String] = [lines[0]]
        var replaced = false
        for line in lines.dropFirst() {
            if !replaced,
               let data = line.data(using: .utf8),
               let parsed = try? SessionJSONLTranscriptCodec.entry(fromLineJSON: data),
               parsed.entryId == entryId
            {
                let newData = try SessionJSONLTranscriptCodec.jsonlData(for: entry)
                let newLine = String(decoding: newData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(newLine)
                replaced = true
            } else {
                out.append(line)
            }
        }
        guard replaced else {
            throw SessionPersistenceError.entryNotFound(conversationID: conversationID, entryId: entryId)
        }
        let joined = out.joined(separator: "\n") + "\n"
        guard let outData = joined.data(using: .utf8) else {
            throw SessionJSONLTranscriptWriterError.encodingFailed
        }
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).jsonl", isDirectory: false)
        try outData.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    /// Rewrites transcript body lines atomically (caller holds transcript write lock).
    static func rewriteTranscript(fileURL: URL, parsed: ParsedTranscriptFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let headerData = try? enc.encode(parsed.header) else {
            throw SessionJSONLTranscriptWriterError.encodingFailed
        }
        var out = Data()
        out.append(headerData)
        out.append(0x0A)
        for entry in parsed.entries.sorted(by: { $0.sequence < $1.sequence }) {
            out.append(try SessionJSONLTranscriptCodec.jsonlData(for: entry))
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).jsonl", isDirectory: false)
        try out.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    private func writeAtomically(_ data: Data) throws {
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).jsonl", isDirectory: false)
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    /// Drops the last newline-terminated row after the session header (Gap 5 rollback). Assumes one JSON object per line.
    static func truncateLastEntryLine(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionJSONLTranscriptWriterError.transcriptFileMissing
        }
        var text = try String(contentsOf: fileURL, encoding: .utf8)
        if text.hasSuffix("\n") { text.removeLast() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        guard lines.count >= 2 else {
            throw SessionJSONLTranscriptWriterError.transcriptTruncateInvalid
        }
        lines.removeLast()
        let newText = lines.joined(separator: "\n") + "\n"
        guard let out = newText.data(using: .utf8) else {
            throw SessionJSONLTranscriptWriterError.encodingFailed
        }
        try out.write(to: fileURL, options: .atomic)
    }

    /// Preserves corrupt transcript bytes before rewrite (`<id>.jsonl.corrupt-<timestamp>`).
    static func sideCopyCorruptTranscript(fileURL: URL, now: Date = Date()) throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionJSONLTranscriptWriterError.transcriptFileMissing
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let copyURL = fileURL.deletingPathExtension()
            .appendingPathExtension("jsonl.corrupt-\(stamp)")
        if FileManager.default.fileExists(atPath: copyURL.path) {
            return copyURL
        }
        try FileManager.default.copyItem(at: fileURL, to: copyURL)
        return copyURL
    }
}
