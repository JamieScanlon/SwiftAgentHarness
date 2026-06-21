//
//  Read authoritative transcript from JSONL (line 1 = session header; remaining lines = entries).
//

import Foundation

/// Parsed JSONL transcript: header + body entries (idempotent on read; does not rewrite disk).
struct ParsedTranscriptFile: Sendable, Equatable {
    var header: SessionJSONLHeader
    var entries: [SessionTranscriptEntry]
}

enum SessionJSONLTranscriptReaderError: Error, Sendable, Equatable {
    case transcriptFileMissing
    case invalidUTF8
    case invalidHeader
}

struct TranscriptLineScanResult: Sendable, Equatable {
    var damageClass: TranscriptDamageClass
    var lastCleanJSONLSequence: Int
    var reason: String?
}

enum SessionJSONLTranscriptReader {
    /// Loads all entries from JSONL (skips header). Fails if file missing or unreadable.
    /// Whitespace-only / empty files yield `[]` (no header required).
    static func loadEntries(fileURL: URL) throws -> [SessionTranscriptEntry] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                throw SessionJSONLTranscriptReaderError.transcriptFileMissing
            }
            throw SessionJSONLTranscriptReaderError.invalidUTF8
        }
        return try parseEntryLines(from: raw)
    }

    /// Header + entries; requires at least one non-empty line that decodes as a supported session header.
    static func loadParsed(fileURL: URL) throws -> ParsedTranscriptFile {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                throw SessionJSONLTranscriptReaderError.transcriptFileMissing
            }
            throw SessionJSONLTranscriptReaderError.invalidUTF8
        }
        return try parseTranscript(from: raw)
    }

    /// Parses UTF-8 text of a JSONL file; first non-empty line must decode as session header.
    static func parseEntryLines(from fileText: String) throws -> [SessionTranscriptEntry] {
        var lines = fileText.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return [] }
        return try parseTranscript(from: fileText).entries
    }

    /// Counts non-header JSONL body lines without decoding entries (cheap drift detection).
    static func entryLineCount(fileURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionJSONLTranscriptReaderError.transcriptFileMissing
        }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw SessionJSONLTranscriptReaderError.invalidUTF8
        }
        var lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return 0 }
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? JSONDecoder().decode(SessionJSONLHeader.self, from: headerData),
              header.type == "session",
              SessionJSONLTranscriptFormat.isSupportedHeaderVersion(header.version)
        else {
            throw SessionJSONLTranscriptReaderError.invalidHeader
        }
        return max(0, lines.count - 1)
    }

    static func parseTranscript(from fileText: String) throws -> ParsedTranscriptFile {
        var lines = fileText.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw SessionJSONLTranscriptReaderError.invalidHeader
        }
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? JSONDecoder().decode(SessionJSONLHeader.self, from: headerData),
              header.type == "session",
              SessionJSONLTranscriptFormat.isSupportedHeaderVersion(header.version)
        else {
            throw SessionJSONLTranscriptReaderError.invalidHeader
        }
        var entries: [SessionTranscriptEntry] = []
        for line in lines.dropFirst() {
            guard let data = line.data(using: .utf8),
                  let entry = try? SessionJSONLTranscriptCodec.entry(
                      fromLineJSON: data,
                      transcriptHeaderVersion: header.version
                  )
            else { continue }
            entries.append(entry)
        }
        return ParsedTranscriptFile(header: header, entries: entries)
    }

    static func filter(entries: [SessionTranscriptEntry], request: SessionTranscriptReadRequest) -> [SessionTranscriptEntry] {
        var out = entries
        if let from = request.fromSequence {
            out = out.filter { $0.sequence >= from }
        }
        if let to = request.toSequence {
            out = out.filter { $0.sequence <= to }
        }
        if let limit = request.limit {
            guard limit > 0 else { return [] }
            if out.count > limit {
                out = Array(out.prefix(limit))
            }
        }
        return out
    }

    /// Strict line-by-line scan for integrity verify (does not skip bad lines).
    static func verifyLineScan(fileURL: URL, catalogLatestSequence: Int) throws -> TranscriptLineScanResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if catalogLatestSequence > 0 {
                return TranscriptLineScanResult(
                    damageClass: .missingFile,
                    lastCleanJSONLSequence: 0,
                    reason: "transcript file missing"
                )
            }
            return TranscriptLineScanResult(damageClass: .clean, lastCleanJSONLSequence: 0, reason: nil)
        }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return TranscriptLineScanResult(
                damageClass: .structural,
                lastCleanJSONLSequence: 0,
                reason: "invalid UTF-8"
            )
        }
        return verifyLineScan(from: raw, catalogLatestSequence: catalogLatestSequence)
    }

    static func verifyLineScan(from fileText: String, catalogLatestSequence: Int) -> TranscriptLineScanResult {
        var lines = fileText.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty {
            return TranscriptLineScanResult(damageClass: .clean, lastCleanJSONLSequence: 0, reason: nil)
        }
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? JSONDecoder().decode(SessionJSONLHeader.self, from: headerData),
              header.type == "session"
        else {
            return TranscriptLineScanResult(
                damageClass: .structural,
                lastCleanJSONLSequence: 0,
                reason: "invalid header"
            )
        }
        if !SessionJSONLTranscriptFormat.isSupportedHeaderVersion(header.version) {
            return TranscriptLineScanResult(
                damageClass: .clean,
                lastCleanJSONLSequence: 0,
                reason: "unsupported header version \(header.version)"
            )
        }
        let bodyLines = Array(lines.dropFirst())
        if bodyLines.isEmpty {
            return TranscriptLineScanResult(damageClass: .clean, lastCleanJSONLSequence: 0, reason: nil)
        }
        var lastCleanSequence = 0
        for (index, line) in bodyLines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? SessionJSONLTranscriptCodec.entry(
                      fromLineJSON: data,
                      transcriptHeaderVersion: header.version
                  )
            else {
                let isTail = index == bodyLines.count - 1
                return TranscriptLineScanResult(
                    damageClass: isTail ? .tailConfined : .structural,
                    lastCleanJSONLSequence: lastCleanSequence,
                    reason: "undecodable body line \(index + 1)"
                )
            }
            lastCleanSequence = entry.sequence
        }
        return TranscriptLineScanResult(
            damageClass: .clean,
            lastCleanJSONLSequence: lastCleanSequence,
            reason: nil
        )
    }
}
