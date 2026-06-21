//
//  Catalog-independent conversation id discovery from `sessions.json` + `agents/<agentId>/sessions/*.jsonl` (Gap 12).
//

import Foundation

/// Bounded “lite” reads for recovery UX when the SQLite catalog is missing or incomplete (harness README analog).
enum SessionPersistenceLiteRecovery {
    private static let recoveryFormatV1 = "sah-sessions-recovery-v1"

    private struct RecoveryIndexBody: Decodable, Sendable {
        var format: String
        var conversationIds: [String]
    }

    /// Hyphenated UUID (case-insensitive hex).
    private static let uuidRegex: NSRegularExpression = {
        guard let r = try? NSRegularExpression(
            pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        ) else {
            preconditionFailure("SessionPersistenceLiteRecovery uuid regex")
        }
        return r
    }()

    /// Union of: structured `sessions.json`, regex harvest from damaged `sessions.json` head/tail, `*.jsonl` basenames,
    /// and optional first-line ``SessionJSONLHeader`` `id` when it parses.
    ///
    /// Best-effort: returns **sorted** ids; does not throw (I/O failures yield partial results).
    static func discoverConversationIds(root: URL, agentId: String) -> [UUID] {
        var found = Set<UUID>()
        let scanN = SessionPersistenceConfiguration.liteRecoveryScanBytes
        ingestSessionsJson(root: root, into: &found, scanN: scanN)
        ingestJsonlDirectory(root: root, agentId: agentId, into: &found)
        return found.sorted()
    }

    private static func ingestSessionsJson(root: URL, into found: inout Set<UUID>, scanN: Int) {
        let url = SessionPersistenceLayout.sessionsRecoveryIndexURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }

        if let decoded = try? JSONDecoder().decode(RecoveryIndexBody.self, from: data),
           decoded.format == recoveryFormatV1 {
            for s in decoded.conversationIds {
                if let u = UUID(uuidString: s) { found.insert(u) }
            }
            return
        }

        if data.count <= scanN * 2 {
            let s = String(decoding: data, as: UTF8.self)
            harvestUuids(from: s, into: &found)
            return
        }

        let headStr = data.prefix(scanN).withUnsafeBytes { raw in
            String(decoding: raw, as: UTF8.self)
        }
        harvestUuids(from: headStr, into: &found)
        let tailStart = data.count - scanN
        let tail = data.suffix(from: tailStart)
        let tailStr = String(decoding: tail, as: UTF8.self)
        harvestUuids(from: tailStr, into: &found)
    }

    private static func harvestUuids(from string: String, into found: inout Set<UUID>) {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        uuidRegex.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: string) else { return }
            let sub = String(string[r])
            if let u = UUID(uuidString: sub) { found.insert(u) }
        }
    }

    private static func ingestJsonlDirectory(root: URL, agentId: String, into found: inout Set<UUID>) {
        let dir = SessionPersistenceLayout.agentSessionsDirectory(root: root, agentId: agentId)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let peek = SessionPersistenceConfiguration.liteRecoveryJsonlHeaderPeekBytes
        for url in urls {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            if let fromName = UUID(uuidString: base) {
                found.insert(fromName)
            }
            if let headerId = headerSessionId(fromJsonl: url, maxBytes: peek) {
                found.insert(headerId)
            }
        }
    }

    private static func headerSessionId(fromJsonl url: URL, maxBytes: Int) -> UUID? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let chunk = try? fh.read(upToCount: maxBytes), !chunk.isEmpty else { return nil }
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let lineData = first.data(using: .utf8) else { return nil }
        guard let header = try? JSONDecoder().decode(SessionJSONLHeader.self, from: lineData) else { return nil }
        guard header.type == "session" else { return nil }
        return UUID(uuidString: header.id)
    }
}
