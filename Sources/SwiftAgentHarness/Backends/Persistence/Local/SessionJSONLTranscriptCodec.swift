//
//  Shared JSONL body line encode/decode (header is separate SessionJSONLHeader).
//

import Foundation

/// One transcript entry line after the versioned session header.
struct SessionJSONLTranscriptBodyLine: Codable, Sendable, Equatable {
    var sequence: Int
    var id: String
    var parentId: String?
    var type: String
    var timestamp: Date
    var payloadJSON: String

    func asEntry(transcriptHeaderVersion: Int) -> SessionTranscriptEntry {
        let entryType = SessionTranscriptEntryType.decoding(from: type, transcriptHeaderVersion: transcriptHeaderVersion)
        let hint: String? = entryType == .custom ? type : nil
        let entryId = SessionEntryID(id) ?? SessionEntryID.generate()
        let parent = parentId.flatMap(SessionEntryID.init)
        return SessionTranscriptEntry(
            sequence: sequence,
            entryId: entryId,
            parentEntryId: parent,
            type: entryType,
            harnessTypeRaw: hint,
            timestamp: timestamp,
            payloadJSON: payloadJSON
        )
    }
}

enum SessionJSONLTranscriptCodec {
    static func jsonlData(for entry: SessionTranscriptEntry) throws -> Data {
        let line = SessionJSONLTranscriptBodyLine(
            sequence: entry.sequence,
            id: entry.entryId.rawValue,
            parentId: entry.parentEntryId?.rawValue,
            type: entry.persistedTypeRaw,
            timestamp: entry.timestamp,
            payloadJSON: entry.payloadJSON
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(line)
    }

    static func entry(fromLineJSON data: Data, transcriptHeaderVersion: Int) throws -> SessionTranscriptEntry {
        let dec = JSONDecoder()
        let line = try dec.decode(SessionJSONLTranscriptBodyLine.self, from: data)
        return line.asEntry(transcriptHeaderVersion: transcriptHeaderVersion)
    }

    /// Decode a body line without JSONL header context (e.g. unit tests); uses newest supported header rules.
    static func entry(fromLineJSON data: Data) throws -> SessionTranscriptEntry {
        try entry(fromLineJSON: data, transcriptHeaderVersion: SessionJSONLTranscriptFormat.maxSupportedHeaderVersion)
    }
}
